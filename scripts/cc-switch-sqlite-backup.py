import json
import os
import sqlite3
import sys
import time


def fail(code):
    print(json.dumps({"ok": False, "code": code}, separators=(",", ":")))
    return 1


def is_reparse(path):
    try:
        return bool(os.stat(path, follow_symlinks=False).st_file_attributes & 0x400)
    except (AttributeError, OSError):
        return False


def main():
    if len(sys.argv) != 5 or sys.argv[1] != "backup":
        return fail("arguments")
    source_root = os.path.abspath(sys.argv[2])
    stage_root = os.path.abspath(sys.argv[3])
    try:
        timeout_seconds = int(sys.argv[4])
    except ValueError:
        return fail("arguments")
    if timeout_seconds < 1 or timeout_seconds > 5:
        return fail("arguments")
    src = os.path.join(source_root, "config", "cc-switch", "home", ".cc-switch", "cc-switch.db")
    dst = os.path.join(stage_root, "config", "cc-switch", "home", ".cc-switch", "cc-switch.db")
    try:
        if not os.path.isfile(src) or is_reparse(src) or os.path.lexists(dst):
            return fail("path")
        src_parent = os.path.dirname(src)
        dst_parent = os.path.dirname(dst)
        if is_reparse(src_parent) or is_reparse(dst_parent):
            return fail("reparse")
        wal = src + "-wal"
        shm = src + "-shm"
        sidecar_total = 0
        for candidate in (src, wal, shm):
            if os.path.lexists(candidate):
                if is_reparse(candidate) or not os.path.isfile(candidate):
                    return fail("sidecar")
                size = os.path.getsize(candidate)
                sidecar_total += size
                if candidate == src and size > 20 * 1024 * 1024:
                    return fail("size")
        if sidecar_total > 100 * 1024 * 1024:
            return fail("size")
        deadline = time.monotonic() + timeout_seconds
        uri = "file:" + src.replace("\\", "/") + "?mode=ro"
        source = sqlite3.connect(uri, uri=True, timeout=max(0.001, deadline - time.monotonic()))
        if time.monotonic() >= deadline:
            return fail("timeout")
        target = sqlite3.connect(dst, timeout=max(0.001, deadline - time.monotonic()))
        if time.monotonic() >= deadline:
            return fail("timeout")

        def progress(status, remaining, total):
            if time.monotonic() >= deadline:
                raise TimeoutError()
            current_total = 0
            for candidate in (src, wal, shm):
                if os.path.lexists(candidate):
                    if is_reparse(candidate) or not os.path.isfile(candidate):
                        raise RuntimeError()
                    current_total += os.path.getsize(candidate)
            if current_total > 100 * 1024 * 1024 or os.path.getsize(src) > 20 * 1024 * 1024:
                raise RuntimeError()

        target.set_progress_handler(lambda: 1 if time.monotonic() >= deadline else 0, 1000)
        source.backup(target, pages=256, progress=progress, sleep=0.05)
        result = target.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            source.close()
            target.close()
            return fail("integrity")
        target.close()
        source.close()
        print(json.dumps({"ok": True, "integrity": "ok"}, separators=(",", ":")))
        return 0
    except TimeoutError:
        return fail("timeout")
    except Exception:
        if "deadline" in locals() and time.monotonic() >= deadline:
            return fail("timeout")
        return fail("sqlite")


if __name__ == "__main__":
    sys.exit(main())
