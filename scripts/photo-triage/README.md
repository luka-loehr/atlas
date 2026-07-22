# photo-triage — Schrott-Fotos aussortieren

Einmal-Werkzeug: findet Lösch-Kandidaten (Screenshots, Unscharfes,
Leeres/Schwarzes, Dokumente) und zeigt sie einzeln — Bild links, Details und
Steuerung rechts. **Backspace** = Papierkorb, **Enter** = behalten,
**U** = rückgängig. Löschen ist reversibel (setzt nur `trashed_at`; endgültig
erst beim Leeren des Papierkorbs in der App).

Fortschritt liegt serverseitig in `decided.json` und wird beim Laden mit dem
echten Papierkorb auf atlas abgeglichen — Reload oder Browserwechsel zeigen
nie wieder bereits Entschiedenes.

## Kandidaten erzeugen

```bash
# 1) Metadaten der sichtbaren Fotos (ohne Favoriten) aus Postgres -> assets.json
# 2) Blur/Einfarbigkeit ueber die 512er-Thumbs (pipeline-cpu-Container, ~9 s):
docker cp triage_score.py atlas-pipeline-pipeline-cpu-1:/tmp/
docker exec atlas-pipeline-pipeline-cpu-1 \
  python3 /tmp/triage_score.py /tmp/assets.json /tmp/scores.json

# 3) Semantische Muell-Konzepte via Qwen-Embeddings (auf dem atlas-Host):
python3 triage_sem.py           # -> sem.json

# 4) Zusammenfuehren (Schwellwerte siehe Commit-Historie) -> candidates.json
```

Signale: Dateiname/`PNG`+Display-Auflösung (Screenshots), Laplace-Varianz
unterste ~3 % (unscharf), Grauwert-Streuung < 0.05 (einfarbig), Cosine-Nähe
zu Konzepttexten wie „paper document, receipt" (Dokumente).

## Benutzen

```bash
python3 serve.py                # -> http://localhost:8890
```

`serve.py` liefert die Seite und proxied `/trash` + `/restore` an den
atlas-Server (gleiche Origin, kein CORS). Bilder kommen direkt vom
atlas-photos-Server; dessen Basis-URL kommt aus `ATLAS_PHOTOS_URL`
(Default: `http://atlas.your-tailnet.ts.net:8788`).
