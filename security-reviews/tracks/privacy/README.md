# Track: Privacy (`luka-loehr/atlas`)

Audits personal data handling, EXIF/location metadata, face/people embeddings, public share exposure, and logging hygiene across `luka-loehr/atlas`.

## Key questions

1. Do public Share Worker pages or OG image endpoints strip or avoid exposing sensitive metadata (GPS coordinates, internal paths, private album names, owner emails) unless explicitly intended?
2. Are biometric/face embeddings, OCR text, and search queries kept strictly within the authenticated boundary and excluded from public or unauthenticated caches?
3. Do server logs, error responses, and CLI diagnostics avoid recording personal filenames, query tokens, or user credentials?
4. Does trashing or deleting an asset/file propagate cleanly to derived thumbnails, previews, OCR text, and face/vector records?
