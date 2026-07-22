#!/usr/bin/env python3
"""Extract searchable text from drive blobs into drive_files.text.

Covers: plain text (txt/md/csv/json/xml/html/code), PDF (pdftotext),
docx/pptx (Office XML, tags stripped), xlsx (sharedStrings). Everything else
(audio, video, zips, GoodNotes) stores '' so it isn't rescanned.

    python3 extract_drive_text.py              # backfill: all rows with text IS NULL
    python3 extract_drive_text.py --all        # re-extract everything
    python3 extract_drive_text.py --file-id N  # one file (used by the upload hook)
"""
import os
import re
import subprocess
import sys
import zipfile

import psycopg

BLOBS = os.path.expanduser("~/drive/blobs")
CAP = 200_000  # chars per file — plenty for search, keeps rows small

TEXT_EXT = {"txt", "md", "csv", "log", "json", "xml", "html", "htm", "js", "ts",
            "py", "swift", "rs", "c", "cpp", "h", "sh", "yml", "yaml", "toml",
            "ini", "tex", "srt", "vtt"}


def db():
    pw = ""
    with open(os.path.expanduser("~/atlas/backend/docker/.env")) as f:
        for line in f:
            if line.startswith("POSTGRES_PASSWORD="):
                pw = line.split("=", 1)[1].strip()
    return psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas", password=pw)


def strip_xml(xml):
    # tag boundaries become spaces so words from adjacent runs don't glue
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", xml)).strip()


def office_xml(path, members):
    out = []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        for pattern in members:
            for m in sorted(n for n in names if re.fullmatch(pattern, n)):
                out.append(strip_xml(z.read(m).decode("utf-8", "ignore")))
                if sum(len(o) for o in out) > CAP:
                    return " ".join(out)
    return " ".join(out)


def extract(path, name):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    try:
        if ext in TEXT_EXT:
            with open(path, "rb") as f:
                return f.read(CAP * 4).decode("utf-8", "ignore")
        if ext == "pdf":
            r = subprocess.run(["pdftotext", path, "-"], capture_output=True,
                               text=True, timeout=120)
            return r.stdout
        if ext == "docx":
            return office_xml(path, [r"word/document\.xml"])
        if ext == "pptx":
            return office_xml(path, [r"ppt/slides/slide\d+\.xml"])
        if ext == "xlsx":
            return office_xml(path, [r"xl/sharedStrings\.xml"])
    except Exception as e:
        print(f"  ! {name}: {e}", file=sys.stderr)
    return ""


def main():
    conn = db()
    cur = conn.cursor()
    if "--file-id" in sys.argv:
        cur.execute("SELECT id, name, hash FROM drive_files WHERE id = %s",
                    (int(sys.argv[sys.argv.index("--file-id") + 1]),))
    elif "--all" in sys.argv:
        cur.execute("SELECT id, name, hash FROM drive_files")
    else:
        cur.execute("SELECT id, name, hash FROM drive_files WHERE text IS NULL")
    rows = cur.fetchall()
    filled = 0
    for n, (id, name, digest) in enumerate(rows, 1):
        text = extract(os.path.join(BLOBS, digest), name)
        text = re.sub(r"\s+", " ", text)[:CAP].strip()
        cur.execute("UPDATE drive_files SET text = %s WHERE id = %s", (text, id))
        if text:
            filled += 1
        if n % 100 == 0:
            conn.commit()
            print(f"  {n}/{len(rows)}")
    conn.commit()
    print(f"done: {len(rows)} processed, {filled} with text")
    conn.close()


if __name__ == "__main__":
    main()
