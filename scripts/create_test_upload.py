#!/usr/bin/env python3
"""Create harmless artifacts to exercise the real Release publishing path."""
import hashlib
from pathlib import Path

upload = Path("/upload")
upload.mkdir(parents=True, exist_ok=True)
for name in ["readme-test.txt", "readme-test.manifest"]:
    (upload / name).write_text("README workflow test only. Not firmware. Do not flash.\n", encoding="utf-8")
checksums = [f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}\n"
             for f in sorted(upload.iterdir()) if f.is_file() and f.name != "sha256sums"]
(upload / "sha256sums").write_text("".join(checksums), encoding="utf-8")
