"""qwen3vl-Vektoren + Personen-Identitaet -> PCA(50) -> UMAP(3D) -> layout.json

Warum die Personen mit in den Vektor muessen: die Bild-Embeddings beschreiben
BILDINHALT, nicht Identitaet. Ohne diesen Schritt liegen Fotos derselben Person
ueber die ganze Wolke verstreut (Strandfoto zu Strand, Kuechenfoto zu Kueche)
und ein "Flug nach Kroatien" haette kein Ziel. Deshalb:

    feature = [ normalize(PCA50) , W * normalize(person_onehot) ]

Mit cosine-Metrik ziehen sich dadurch Fotos mit gleicher Person an, ohne dass
die semantische Grobstruktur verloren geht. W steuert die Staerke.

Die Zeilenreihenfolge ist mit ORDER BY festgenagelt — layout.json und die
Sprite-Atlanten muessen dieselbe Sequenz haben, sonst sitzt jedes Foto falsch.
"""
import json, time
import numpy as np
import psycopg

PERSON_WEIGHT = 0.75

pw = [l.split("=", 1)[1].strip() for l in open("/secrets/.env")
      if l.startswith("POSTGRES_PASSWORD")][0]
conn = psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas", password=pw)
cur = conn.cursor()

t0 = time.time()
cur.execute("""
    SELECT e.owner_id,
           e.vec::text,
           a.type,
           (SELECT t.tag FROM tags t WHERE t.asset_id = a.id ORDER BY t.tag LIMIT 1),
           EXTRACT(YEAR FROM a.taken_at)::int
    FROM embeddings e
    JOIN assets a ON a.id = e.owner_id
    WHERE e.model = 'qwen3vl'
      AND NOT a.archived AND a.trashed_at IS NULL AND NOT a.locked
    ORDER BY e.owner_id
""")
rows = cur.fetchall()
n = len(rows)
print(f"geladen: {n} Vektoren in {time.time()-t0:.1f}s", flush=True)

ids   = [r[0] for r in rows]
types = [r[2] for r in rows]
tags  = [r[3] or "" for r in rows]
years = [r[4] if r[4] else 0 for r in rows]
idx   = {a: i for i, a in enumerate(ids)}

# --- Personen pro Asset -------------------------------------------------
cur.execute("""
    SELECT f.asset_id, p.display_name
    FROM faces f JOIN persons p ON p.id = f.person_id
    WHERE p.display_name IS NOT NULL AND p.display_name <> ''
      AND p.merged_into IS NULL
    GROUP BY f.asset_id, p.display_name
""")
per_asset = [[] for _ in range(n)]
names = {}
for aid, nm in cur.fetchall():
    i = idx.get(aid)
    if i is None:
        continue
    if nm not in names:
        names[nm] = len(names)
    if nm not in per_asset[i]:
        per_asset[i].append(nm)
n_persons = len(names)
with_person = sum(1 for p in per_asset if p)
print(f"Personen: {n_persons} benannt, auf {with_person} Fotos", flush=True)

# --- Bildvektoren -------------------------------------------------------
t0 = time.time()
X = np.array([np.fromstring(r[1][1:-1], sep=",", dtype=np.float32) for r in rows],
             dtype=np.float32)
print(f"Matrix {X.shape} geparst in {time.time()-t0:.1f}s", flush=True)

from sklearn.decomposition import PCA
t0 = time.time()
X50 = PCA(n_components=50, svd_solver="randomized", random_state=42).fit_transform(X)
X50 /= (np.linalg.norm(X50, axis=1, keepdims=True) + 1e-9)
print(f"PCA -> {X50.shape} in {time.time()-t0:.1f}s", flush=True)

P = np.zeros((n, n_persons), dtype=np.float32)
for i, ps in enumerate(per_asset):
    for nm in ps:
        P[i, names[nm]] = 1.0
nrm = np.linalg.norm(P, axis=1, keepdims=True)
P = np.divide(P, nrm, out=np.zeros_like(P), where=nrm > 0) * PERSON_WEIGHT

F = np.hstack([X50, P]).astype(np.float32)
print(f"Feature {F.shape} (Bild 50 + Person {n_persons} @ w={PERSON_WEIGHT})", flush=True)

# --- UMAP 3D ------------------------------------------------------------
t0 = time.time()
import umap
xyz = umap.UMAP(n_components=3, n_neighbors=25, min_dist=0.12,
                metric="cosine", random_state=42, verbose=True).fit_transform(F)
print(f"UMAP 3D fertig in {time.time()-t0:.1f}s", flush=True)

xyz = np.asarray(xyz, dtype=np.float32)
xyz -= (xyz.min(0) + xyz.max(0)) / 2.0
xyz /= np.abs(xyz).max()

out = {
    "n": n,
    "ids": ids,
    "x": [round(float(v), 5) for v in xyz[:, 0]],
    "y": [round(float(v), 5) for v in xyz[:, 1]],
    "z": [round(float(v), 5) for v in xyz[:, 2]],
    "type": types,
    "tag": tags,
    "year": years,
    "persons": per_asset,
    "personNames": sorted(names.keys()),
}
with open("/work/layout.json", "w") as f:
    json.dump(out, f)
print(f"geschrieben: /work/layout.json ({n} Punkte, 3D, {n_persons} Personen)", flush=True)
