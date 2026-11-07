-- AdaFace's estimate of how recognizable a face is (the length of its raw
-- embedding): faces the model cannot make out (blurred, tiny, turned away,
-- or not faces at all) are kept as faces in the photo but never named by
-- resemblance and never gathered into a new person (atlas-ml vision.rs).
ALTER TABLE faces ADD COLUMN IF NOT EXISTS clarity REAL;
