# vecmap — die Vektor-Wolke

3D-Visualisierung aller Foto-Embeddings: UMAP auf 3 Dimensionen, gerendert als
WebGL-Punktwolke aus den echten Thumbnails. Erreichbar unter `/map` auf dem
atlas-photos-Server (Route in `apps/atlas-photos/server`).

## Pipeline

```bash
# 1) Vektoren + Personen -> PCA(50) -> UMAP(3D) -> layout.json
docker run --rm --network host -v /home/atlas/vecmap:/work \
  -v /home/atlas/atlas/backend/docker/.env:/secrets/.env:ro \
  --entrypoint bash atlas-pipeline-cpu -c \
  "pip install --quiet umap-learn scikit-learn; python3 /work/reduce.py"

# 2) alle Thumbnails in 4096er Sprite-Atlanten packen (64px Zellen)
docker run --rm -v /home/atlas/vecmap:/work -v /home/atlas/photos:/photos:ro \
  --entrypoint bash atlas-pipeline-cpu -c "python3 /work/atlas_build.py"

# 3) Bundle ausliefern
sudo cp -r layout.json tiles map.html /home/atlas/photos/vecmap/
```

## Zwei Fallen, die hier teuer sind

**Reihenfolge.** `reduce.py` hat ein `ORDER BY e.owner_id`, und `atlas_build.py`
liest die IDs aus `layout.json`. Beide MUESSEN dieselbe Sequenz haben — Index i
im Layout ist Sprite i im Atlas. Ohne das feste ORDER BY kann Postgres die
Zeilen anders zurueckgeben und jedes Foto sitzt am falschen Punkt. Wer das
Layout neu erzeugt, muss die Atlanten mit neu erzeugen.

**Personen.** Die Bild-Embeddings beschreiben Bildinhalt, nicht Identitaet.
Ohne Zusatz liegen Fotos derselben Person ueber die ganze Wolke verstreut.
Deshalb haengt `reduce.py` einen gewichteten Personen-Anteil an den Vektor
(`PERSON_WEIGHT`, cosine). Gemessene Wirkung bei w=0.75: Ben 11.7x enger als
Zufallspaare, Lena 5.9x, Mia 3.6x — aber Luka nur 1.5x, weil er auf
2883 Fotos in jedem erdenklichen Kontext vorkommt und der Bildinhalt dagegen
haelt. Hoeheres Gewicht = engere Personen-Cluster, aber flachere Semantik.

## Speicher

64px-Sprites, 4096x4096-Atlanten (4096 Bilder pro Atlas). Bei ~24k Fotos sind
das 6 Atlanten / ~30 MB Download und ~400 MB Texturspeicher — bewusst fuer den
Mac ausgelegt, fuer ein iPhone waere das zu viel (dort muesste man auf 32px).
