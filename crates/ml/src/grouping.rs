//! Grouping: who the faces nobody was sure about belong to.
//!
//! The vision stage assigns a face only when its known neighbors agree
//! (vision::decide). Everything else waits here, unassigned. Every few
//! minutes, when new faces arrived:
//!
//!   1. each waiting face is compared with every known face (at most 300 per
//!      person, the person's spread of looks) and assigned the same way: by
//!      now there may be more to compare with than when it was found
//!   2. the faces still waiting are linked to each other where they are
//!      mutually among each other's ten closest and similar enough to be one
//!      person; every linked group of at least three becomes a new
//!      (unnamed) person, for the owner to name
//!
//! The same for animals, per species. Nothing here ever moves a face that
//! already has a person.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use pgvector::Vector;

use crate::Worker;
use crate::vision::{
    self, ASSIGN_ANIMAL, ASSIGN_FACE, ASSIGN_MARGIN, ASSIGN_SMALL_FACE, MIN_CLARITY_ASSIGN, MIN_CLARITY_GROUP, MIN_SCORE_GROUP,
    MODEL, SMALL_FACE,
};

const EVERY: Duration = Duration::from_secs(5 * 60);
const EXEMPLARS_PER_PERSON: i64 = 300;
const NEIGHBORS: usize = 10;
/// Two waiting faces this similar may be one person ...
const LINK_FACE: f32 = 0.45;
const LINK_ANIMAL: f32 = 0.55;
/// ... and this many linked make one.
const MIN_GROUP: usize = 3;

pub async fn run(worker: Arc<Worker>) {
    let mut last_seen: i64 = 0;
    loop {
        tokio::time::sleep(EVERY).await;
        let newest = match newest_face(&worker).await {
            Ok(id) => id,
            Err(e) => {
                tracing::warn!("grouping: {e:#}");
                continue;
            }
        };
        if newest == last_seen {
            continue;
        }
        match pass(&worker).await {
            Ok((assigned, created)) => {
                last_seen = newest;
                if assigned + created > 0 {
                    tracing::info!("grouping: {assigned} faces assigned, {created} new people and pets");
                }
            }
            Err(e) => tracing::warn!("grouping: {e:#}"),
        }
    }
}

async fn newest_face(worker: &Worker) -> Result<i64> {
    let c = worker.pool.get().await?;
    Ok(c.query_one("SELECT coalesce(max(id), 0) FROM faces", &[]).await?.get(0))
}

struct Item {
    id: i64,
    vector: Vec<f32>,
    width: f32,
    /// clear and sure enough to found a new person
    founder: bool,
}

/// One pass over people and every species; (faces assigned, people made).
pub async fn pass(worker: &Worker) -> Result<(usize, usize)> {
    let (mut assigned, mut created) = (0, 0);
    let c = worker.pool.get().await?;
    let kinds: Vec<String> = c
        .query("SELECT DISTINCT kind FROM faces WHERE person_id IS NULL", &[])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    drop(c);
    for kind in kinds {
        let (a, n) = group_kind(worker, &kind).await?;
        assigned += a;
        created += n;
    }
    Ok((assigned, created))
}

async fn group_kind(worker: &Worker, kind: &str) -> Result<(usize, usize)> {
    let face = kind == "person";
    let column = if face { "embedding" } else { "look" };
    // faces: the current recognizer's, clear enough to be named at all
    let model_filter =
        if face { format!("AND f.model = '{MODEL}' AND coalesce(f.clarity, 0) >= {MIN_CLARITY_ASSIGN}") } else { String::new() };
    let mut c = worker.pool.get().await?;
    // a spread of each person's looks: the most confident detections
    let known_rows = c
        .query(
            &format!(
                "SELECT person_id, v FROM (
                     SELECT f.person_id, f.{column} AS v,
                            row_number() OVER (PARTITION BY f.person_id ORDER BY f.quality * f.width_px DESC NULLS LAST) AS n
                     FROM faces f JOIN persons p ON p.id = f.person_id AND p.merged_into IS NULL
                     WHERE f.kind = $1 AND f.{column} IS NOT NULL {model_filter}
                 ) x WHERE n <= $2"
            ),
            &[&kind, &EXEMPLARS_PER_PERSON],
        )
        .await?;
    let known: Vec<(i64, Vec<f32>)> = known_rows.iter().map(|r| (r.get(0), r.get::<_, Vector>(1).to_vec())).collect();
    let waiting: Vec<Item> = c
        .query(
            &format!(
                "SELECT f.id, f.{column}, coalesce(f.width_px, 0),
                        coalesce(f.clarity, 99) >= {MIN_CLARITY_GROUP} AND coalesce(f.quality, 0) >= {MIN_SCORE_GROUP}
                 FROM faces f
                 WHERE f.kind = $1 AND f.person_id IS NULL AND f.{column} IS NOT NULL {model_filter}"
            ),
            &[&kind],
        )
        .await?
        .iter()
        .map(|r| Item { id: r.get(0), vector: r.get::<_, Vector>(1).to_vec(), width: r.get(2), founder: r.get(3) })
        .collect();
    if waiting.is_empty() {
        return Ok((0, 0));
    }

    // 1. by now someone may be recognizable
    let decisions: Vec<Option<i64>> = {
        let known = &known;
        parallel_map(&waiting, |item| {
            let mut neighbors: Vec<(i64, f32)> = known.iter().map(|(p, v)| (*p, dot(&item.vector, v))).collect();
            let k = neighbors.len().min(40);
            if k == 0 {
                return None;
            }
            neighbors.select_nth_unstable_by(k - 1, |a, b| b.1.total_cmp(&a.1));
            neighbors.truncate(k);
            let threshold = if !face {
                ASSIGN_ANIMAL
            } else if item.width < SMALL_FACE {
                ASSIGN_SMALL_FACE
            } else {
                ASSIGN_FACE
            };
            vision::decide(&neighbors, threshold, ASSIGN_MARGIN)
        })
    };
    let mut assignments: HashMap<i64, Vec<i64>> = HashMap::new();
    let mut rest = Vec::new();
    for (item, decision) in waiting.into_iter().zip(decisions) {
        match decision {
            Some(person) => assignments.entry(person).or_default().push(item.id),
            None => rest.push(item),
        }
    }
    let assigned: usize = assignments.values().map(Vec::len).sum();

    // 2. the rest among themselves: only faces clear enough found someone
    let link = if face { LINK_FACE } else { LINK_ANIMAL };
    rest.retain(|item| !face || item.founder);
    let groups = gather(&rest, link);

    let tx = c.transaction().await?;
    let mut touched: Vec<i64> = Vec::new();
    for (person, faces) in &assignments {
        attach(&tx, *person, faces).await?;
        touched.push(*person);
    }
    for group in &groups {
        let faces: Vec<i64> = group.iter().map(|&i| rest[i].id).collect();
        let person: i64 = tx.query_one("INSERT INTO persons (kind) VALUES ($1) RETURNING id", &[&kind]).await?.get(0);
        attach(&tx, person, &faces).await?;
        touched.push(person);
    }
    vision::refresh_people(&tx, &touched).await?;
    tx.commit().await?;
    Ok((assigned, groups.len()))
}

/// Faces go to a person: their rows, the graph, a cover if there is none.
async fn attach(tx: &tokio_postgres::Transaction<'_>, person: i64, faces: &[i64]) -> Result<()> {
    tx.execute("UPDATE faces SET person_id = $1 WHERE id = ANY($2) AND person_id IS NULL", &[&person, &faces]).await?;
    tx.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
         SELECT DISTINCT 'asset', asset_id, 'depicts', 'person', $1::text, 1.0 FROM faces WHERE id = ANY($2)
         ON CONFLICT DO NOTHING",
        &[&person.to_string(), &faces],
    )
    .await?;
    tx.execute(
        "UPDATE persons SET cover_face_id = (
             SELECT id FROM faces WHERE id = ANY($2) ORDER BY quality * width_px DESC NULLS LAST LIMIT 1)
         WHERE id = $1 AND cover_face_id IS NULL",
        &[&person, &faces],
    )
    .await?;
    Ok(())
}

/// Groups (indices into `items`) of at least [`MIN_GROUP`] linked by mutual
/// closeness: a and b are linked when each is among the other's ten closest
/// and they are at least `link` alike. Mutual links keep a chain of
/// look-alikes from joining two people through a third.
fn gather(items: &[Item], link: f32) -> Vec<Vec<usize>> {
    let n = items.len();
    if n < MIN_GROUP {
        return Vec::new();
    }
    let indices: Vec<usize> = (0..n).collect();
    let closest: Vec<Vec<usize>> = parallel_map(&indices, |&i| {
        let mut sims: Vec<(usize, f32)> = (0..n)
            .filter(|&j| j != i)
            .map(|j| (j, dot(&items[i].vector, &items[j].vector)))
            .filter(|&(_, s)| s >= link)
            .collect();
        sims.sort_by(|a, b| b.1.total_cmp(&a.1));
        sims.truncate(NEIGHBORS);
        sims.into_iter().map(|(j, _)| j).collect()
    });
    let mut parent: Vec<usize> = (0..n).collect();
    fn root(parent: &mut [usize], mut i: usize) -> usize {
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    for i in 0..n {
        for &j in &closest[i] {
            if closest[j].contains(&i) {
                let (a, b) = (root(&mut parent, i), root(&mut parent, j));
                if a != b {
                    parent[a] = b;
                }
            }
        }
    }
    let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        let r = root(&mut parent, i);
        groups.entry(r).or_default().push(i);
    }
    let mut out: Vec<Vec<usize>> = groups.into_values().filter(|g| g.len() >= MIN_GROUP).collect();
    out.sort_by_key(|g| std::cmp::Reverse(g.len()));
    out
}

/// A dot product LLVM can vectorize: eight independent sums.
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut acc = [0f32; 8];
    let (ca, cb) = (a.chunks_exact(8), b.chunks_exact(8));
    let tail: f32 = ca.remainder().iter().zip(cb.remainder()).map(|(x, y)| x * y).sum();
    for (x, y) in ca.zip(cb) {
        for k in 0..8 {
            acc[k] += x[k] * y[k];
        }
    }
    acc.iter().sum::<f32>() + tail
}

/// `f` over `items` on every core, results in order.
fn parallel_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let chunk = items.len().div_ceil(threads).max(1);
    std::thread::scope(|scope| {
        let f = &f;
        let handles: Vec<_> = items.chunks(chunk).map(|part| scope.spawn(move || part.iter().map(f).collect::<Vec<R>>())).collect();
        handles.into_iter().flat_map(|h| h.join().expect("grouping worker panicked")).collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(angle: f32) -> Vec<f32> {
        vec![angle.cos(), angle.sin()]
    }

    #[test]
    fn mutual_neighbors_form_groups_of_three_or_more() {
        // three close together, two others close together, one alone
        let items: Vec<Item> = [0.0, 0.05, 0.1, 2.0, 2.05, 4.0]
            .iter()
            .enumerate()
            .map(|(i, &a)| Item { id: i as i64, vector: unit(a), width: 50.0, founder: true })
            .collect();
        let groups = gather(&items, 0.9);
        assert_eq!(groups.len(), 1);
        let mut g = groups[0].clone();
        g.sort();
        assert_eq!(g, vec![0, 1, 2]);
    }

    #[test]
    fn dot_matches_the_plain_sum() {
        let a: Vec<f32> = (0..19).map(|i| i as f32 * 0.1).collect();
        let b: Vec<f32> = (0..19).map(|i| 1.0 - i as f32 * 0.05).collect();
        let plain: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        assert!((dot(&a, &b) - plain).abs() < 1e-4);
    }
}
