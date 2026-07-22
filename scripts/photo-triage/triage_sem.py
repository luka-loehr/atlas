"""Semantische Schrott-Kandidaten: Distanz jedes Fotos zu 'Muell-Konzepten'.

Laeuft auf dem atlas-Host (nur stdlib): Konzepttext -> Embed-API (8093),
Vektor -> pgvector-Query via docker exec psql. Top-N je Konzept mit Distanz.
"""
import json
import subprocess
import urllib.request

CONCEPTS = {
    "scr":  "a screenshot of a phone screen showing an app, user interface, chat messages or a website",
    "doc":  "a photo of a paper document, receipt, invoice, package label or handwritten notes",
    "blur": "a blurry accidental photo, out of focus or motion blurred, taken by mistake",
    "dark": "a completely black, empty or very dark accidental photo showing nothing",
}
TOP = 1500


def embed(text):
    req = urllib.request.Request(
        "http://127.0.0.1:8093/embed",
        data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))["vec"]


def query(vec):
    lit = "[" + ",".join(f"{x:.6f}" for x in vec) + "]"
    sql = f"""
        SELECT a.id || ' ' || (e.vec <=> '{lit}'::vector)
        FROM embeddings e JOIN assets a ON a.id = e.owner_id
        WHERE e.model='qwen3vl' AND a.type='photo'
          AND NOT a.archived AND a.trashed_at IS NULL AND NOT a.locked AND NOT a.favorite
        ORDER BY e.vec <=> '{lit}'::vector LIMIT {TOP}"""
    out = subprocess.run(
        ["docker", "exec", "-i", "atlas-postgres", "psql", "-U", "atlas",
         "-d", "atlas", "-tA"],
        input=sql, capture_output=True, text=True, check=True).stdout
    return [(i, float(d)) for i, d in
            (line.split() for line in out.strip().splitlines())]


result = {}
for key, text in CONCEPTS.items():
    result[key] = query(embed(text))
    print(key, "best", result[key][0][1], "cut", result[key][-1][1])

json.dump(result, open("/home/atlas/triage/sem.json", "w"))
