#!/usr/bin/env python3
import io
import pathlib
import sqlite3
import sys
import tarfile
import tempfile


def safe_extract(archive: str, destination: pathlib.Path) -> None:
    root = destination.resolve()
    if any(root.iterdir()):
        raise ValueError("destination is not empty")
    allowed_files = {".env", "compose.yaml", "backup-metadata.json"}
    seen: set[str] = set()
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        for member in members:
            path = pathlib.PurePosixPath(member.name)
            parts = path.parts
            if path.is_absolute() or not parts or any(part in ("", ".", "..") for part in parts):
                raise ValueError(f"unsafe path: {member.name}")
            if parts[0] not in ("vw-data", *allowed_files):
                raise ValueError(f"unexpected entry: {member.name}")
            if parts[0] in allowed_files and len(parts) != 1:
                raise ValueError(f"unexpected nested config: {member.name}")
            normalized = path.as_posix().rstrip("/")
            if normalized in seen or not (member.isdir() or member.isfile()):
                raise ValueError(f"duplicate or unsupported entry: {member.name}")
            seen.add(normalized)
        if not {"vw-data", ".env", "compose.yaml"}.issubset(seen):
            raise ValueError("required entry is missing")
        for member in members:
            normalized = pathlib.PurePosixPath(member.name).as_posix().rstrip("/")
            target = (root / pathlib.Path(*pathlib.PurePosixPath(normalized).parts)).resolve()
            if target != root and root not in target.parents:
                raise ValueError(f"path escapes destination: {member.name}")
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = tf.extractfile(member)
                if source is None:
                    raise ValueError(f"cannot read {member.name}")
                with source, target.open("xb") as output:
                    while chunk := source.read(1024 * 1024):
                        output.write(chunk)


def main() -> None:
    archive = sys.argv[1]
    with tempfile.TemporaryDirectory() as temp:
        safe = pathlib.Path(temp) / "safe"
        safe.mkdir()
        safe_extract(archive, safe)
        database = safe / "vw-data" / "db.sqlite3"
        assert database.is_file()
        assert (safe / ".env").is_file()
        assert (safe / "compose.yaml").is_file()
        db = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
        try:
            assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        finally:
            db.close()
        bad_archive = pathlib.Path(temp) / "bad.tar.gz"
        with tarfile.open(bad_archive, "w:gz") as tf:
            info = tarfile.TarInfo("../escape")
            info.size = 4
            tf.addfile(info, io.BytesIO(b"bad!"))
        bad_dest = pathlib.Path(temp) / "bad"
        bad_dest.mkdir()
        try:
            safe_extract(str(bad_archive), bad_dest)
        except ValueError:
            pass
        else:
            raise AssertionError("path-traversal archive was accepted")
        assert not (pathlib.Path(temp) / "escape").exists()
    print("restore archive layout and traversal checks passed")


if __name__ == "__main__":
    main()
