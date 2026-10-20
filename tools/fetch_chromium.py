#!/usr/bin/env python3
"""Download the pinned official Chromium development snapshot over HTTPS."""
import hashlib
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from workspace import ARCHIVE, ARCHIVE_SHA256, DOWNLOAD_URL

ARCHIVE.parent.mkdir(exist_ok=True)
if ARCHIVE.exists():
    with ARCHIVE.open("rb") as f:
        if hashlib.file_digest(f, "sha256").hexdigest() != ARCHIVE_SHA256:
            raise SystemExit("Existing archive checksum mismatch; nothing was overwritten.")
    print("Pinned Chromium archive already verified:", ARCHIVE)
else:
    temporary = ARCHIVE.with_suffix(".partial")
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(DOWNLOAD_URL, timeout=60) as response, temporary.open("xb") as f:
            while data := response.read(1024 * 1024):
                f.write(data)
                digest.update(data)
        if digest.hexdigest() != ARCHIVE_SHA256:
            raise SystemExit("Downloaded archive checksum mismatch; it was not installed.")
        temporary.rename(ARCHIVE)
    finally:
        if temporary.exists(): temporary.unlink()
    print("Downloaded and verified:", ARCHIVE)
