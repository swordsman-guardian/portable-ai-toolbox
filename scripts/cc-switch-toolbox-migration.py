import json
import os
import sqlite3
import sys
import tempfile
import copy
import base64


def emit(ok, code, count=0, current_id=None):
    result = {"ok": bool(ok), "code": code, "count": count}
    if current_id is not None:
        result["currentId"] = current_id
    print(json.dumps(result, separators=(",", ":")))
    return 0


def fail(code):
    emit(False, code)
    return 1


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def read_json_stdin():
    raw_bytes = sys.stdin.buffer.readline(24 * 1024 * 1024 + 1).rstrip(b"\r\n")
    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        raw_bytes = raw_bytes[3:]
    if sys.stdin.buffer.read(1):
        raise ValueError("input-extra")
    if len(raw_bytes) > 24 * 1024 * 1024:
        raise ValueError("input-too-large")
    try:
        raw = raw_bytes.decode("ascii")
    except UnicodeDecodeError:
        raise RuntimeError("stdin-nonascii")
    try:
        decoded = base64.b64decode(raw, validate=True)
    except Exception as exc:
        message = str(exc)
        if "Only base64 data is allowed" in message:
            code = "stdin-base64-char"
        elif "number of data characters" in message or "Incorrect padding" in message:
            code = "stdin-base64-length"
        elif "Excess data after padding" in message:
            code = "stdin-base64-extra-padding"
        elif "Non-base64 digit" in message:
            code = "stdin-base64-digit"
        elif "cannot be 1 more than a multiple of 4" in message:
            code = "stdin-base64-modulo"
        else:
            code = ("stdin-base64-nonascii-" + str(sum(1 for ch in raw if ord(ch) > 127)) +
                    "-nul-" + str(raw.count("\x00")) + "-lenmod-" + str(len(raw) % 4)) if any(ord(ch) > 127 for ch in raw) else "stdin-base64-error"
        raise RuntimeError(code)
    try:
        return json.loads(decoded.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError("stdin-json-" + type(exc).__name__)


def open_db(path):
    if not os.path.isfile(path):
        raise ValueError("missing-db")
    db = sqlite3.connect(path, timeout=10)
    db.execute("PRAGMA foreign_keys=ON")
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version != 19:
        db.close()
        raise ValueError("schema-version")
    integrity = db.execute("PRAGMA integrity_check").fetchone()
    if not integrity or integrity[0] != "ok":
        db.close()
        raise ValueError("db-integrity")
    columns = {row[1] for row in db.execute("PRAGMA table_info(providers)")}
    required = {"id", "app_type", "name", "settings_config", "is_current"}
    if not required.issubset(columns):
        db.close()
        raise ValueError("provider-schema")
    return db


def read_settings(path):
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("settings-root")
    return value


def stage_root_for_db(db_path):
    return os.path.abspath(os.path.join(os.path.dirname(db_path), "..", "..", "..", ".."))


def deep_merge(left, right, owned_env, at=""):
    result = dict(left)
    for key, value in right.items():
        here = (at + "." + key) if at else key
        if key == "env" and at == "":
            a = result.get(key, {})
            b = value
            if not isinstance(a, dict) or not isinstance(b, dict):
                raise ValueError("settings-env")
            merged = dict(a)
            for env_key, env_value in b.items():
                if env_key in owned_env:
                    continue
                if env_key in merged and merged[env_key] != env_value:
                    raise ValueError("settings-conflict")
                merged[env_key] = env_value
            result[key] = merged
            continue
        if key not in result:
            result[key] = value
        elif isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value, owned_env, here)
        elif result[key] != value:
            raise ValueError("settings-conflict")
    return result


def inspect(db_path):
    db = None
    try:
        db = open_db(db_path)
        rows = db.execute(
            "SELECT id, settings_config FROM providers WHERE app_type='claude' AND is_current=1"
        ).fetchall()
        if len(rows) > 1:
            return fail("multiple-current")
        current_id = rows[0][0] if rows else None
        keys = []
        if rows:
            try:
                config = json.loads(rows[0][1])
            except Exception:
                return fail("current-config")
            env = config.get("env", {}) if isinstance(config, dict) else None
            if not isinstance(env, dict):
                return fail("current-config")
            keys = sorted(str(k) for k in env)
        emit(True, "ok", count=len(keys), current_id=current_id)
        # Names only; credential values are deliberately never emitted.
        print(json.dumps({"envKeys": keys}, separators=(",", ":")))
        return 0
    except ValueError as exc:
        return fail(str(exc))
    except Exception:
        return fail("inspect")
    finally:
        if db is not None:
            db.close()


def apply(db_path, payload):
    db = None
    try:
        db = open_db(db_path)
    except ValueError as exc:
        return fail(str(exc))
    except Exception:
        return fail("database")
    current_id = payload.get("currentId")
    rows = payload.get("providers")
    if not isinstance(rows, list) or not rows or not isinstance(current_id, str):
        db.close()
        return fail("input")
    if sum(1 for item in rows if item.get("id") == current_id) != 1:
        db.close()
        return fail("current-missing")

    # db_path is .../config/cc-switch/home/.cc-switch/cc-switch.db.
    stage_root = stage_root_for_db(db_path)
    target_path = os.path.join(stage_root, "harness", "cc-switch", "claude", "settings.json")
    source_settings = read_settings(payload.get("userSettingsPath", "")) if payload.get("userSettingsPath") else {}
    target_settings = read_settings(target_path)
    existing_env_keys = set(payload.get("existingEnvKeys", []))
    if source_settings.get("env") is not None and not isinstance(source_settings.get("env"), dict):
        db.close()
        return fail("settings-env")
    if target_settings.get("env") is not None and not isinstance(target_settings.get("env"), dict):
        db.close()
        return fail("settings-env")
    target_env = target_settings.setdefault("env", {})
    for key in existing_env_keys:
        target_env.pop(key, None)
    owned_env = set()
    for item in rows:
        config = item.get("settings_config", {})
        env = config.get("env", {}) if isinstance(config, dict) else None
        if not isinstance(env, dict):
            db.close()
            return fail("provider-config")
        owned_env.update(env)

    try:
        merged = deep_merge(target_settings, source_settings, owned_env)
        env = merged.setdefault("env", {})
        if not isinstance(env, dict):
            raise ValueError("settings-env")
        for key in owned_env:
            env.pop(key, None)
        current = next(item for item in rows if item["id"] == current_id)
        for key, value in current["settings_config"]["env"].items():
            env[key] = value

        common_settings = copy.deepcopy(merged)
        common_env = common_settings.setdefault("env", {})
        for key in owned_env:
            common_env.pop(key, None)
        for item in rows:
            provider_settings = copy.deepcopy(common_settings)
            provider_env = provider_settings.setdefault("env", {})
            provider_env.update(item["settings_config"]["env"])
            item["settings_config"] = provider_settings

        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        fd, temp_path = tempfile.mkstemp(prefix=".cc-toolbox-settings-", suffix=".tmp",
                                         dir=os.path.dirname(target_path))
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(merged, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())

            db.execute("BEGIN IMMEDIATE")
            for item in rows:
                provider_id = item.get("id")
                name = item.get("name")
                config = item.get("settings_config")
                if not isinstance(provider_id, str) or not isinstance(name, str) or not isinstance(config, dict):
                    raise ValueError("provider-input")
                notes = item.get("notes")
                meta = item.get("meta", {})
                if notes is not None and not isinstance(notes, str):
                    raise ValueError("provider-notes")
                if not isinstance(meta, dict):
                    raise ValueError("provider-meta")
                serialized = canonical(config)
                serialized_meta = canonical(meta)
                exists = db.execute(
                    "SELECT name, settings_config, notes, meta FROM providers WHERE id=? AND app_type='claude'",
                    (provider_id,),
                ).fetchone()
                if exists and (exists[0] != name or canonical(json.loads(exists[1])) != serialized or
                               exists[2] != notes or canonical(json.loads(exists[3] or "{}")) != serialized_meta):
                    raise ValueError("provider-id-conflict")
            db.execute("UPDATE providers SET is_current=0 WHERE app_type='claude'")
            for item in rows:
                provider_id = item["id"]
                name = item["name"]
                serialized = canonical(item["settings_config"])
                exists = db.execute(
                    "SELECT 1 FROM providers WHERE id=? AND app_type='claude'", (provider_id,)
                ).fetchone()
                if exists:
                    db.execute(
                        "UPDATE providers SET is_current=? WHERE id=? AND app_type='claude'",
                        (1 if provider_id == current_id else 0, provider_id),
                    )
                else:
                    db.execute(
                        "INSERT INTO providers(id, app_type, name, settings_config, website_url, category, "
                        "created_at, sort_index, notes, icon, icon_color, meta, is_current) "
                        "VALUES(?, 'claude', ?, ?, NULL, NULL, ?, ?, ?, NULL, NULL, ?, ?)",
                        (provider_id, name, serialized, int(item.get("createdAt", 0)),
                         int(item.get("sortIndex", 0)), item.get("notes"), canonical(item.get("meta", {})),
                         1 if provider_id == current_id else 0),
                    )
            db.commit()
            os.replace(temp_path, target_path)
            temp_path = None
            result = db.execute("PRAGMA integrity_check").fetchone()
            if not result or result[0] != "ok":
                return fail("post-integrity")
            emit(True, "applied", count=len(rows), current_id=current_id)
            return 0
        finally:
            if temp_path and os.path.exists(temp_path):
                os.unlink(temp_path)
    except ValueError as exc:
        db.rollback()
        return fail(str(exc))
    except Exception:
        db.rollback()
        return fail("apply")
    finally:
        db.close()


def verify(db_path, payload):
    db = None
    try:
        db = open_db(db_path)
        rows = payload.get("providers")
        current_id = payload.get("currentId")
        expected_settings = payload.get("expectedClaudeSettings")
        if not isinstance(expected_settings, dict):
            return fail("settings-input")
        owned_env = set()
        for item in rows:
            owned_env.update(item.get("settings_config", {}).get("env", {}).keys())
        common_settings = copy.deepcopy(expected_settings)
        common_env = common_settings.get("env", {})
        if not isinstance(common_env, dict):
            return fail("settings-env")
        for key in owned_env:
            common_env.pop(key, None)
        for item in rows:
            expected_provider = copy.deepcopy(common_settings)
            expected_provider.setdefault("env", {}).update(item["settings_config"]["env"])
            got = db.execute(
                "SELECT name, settings_config, is_current, notes, meta FROM providers WHERE id=? AND app_type='claude'",
                (item["id"],),
            ).fetchone()
            if not got or got[0] != item["name"]:
                return fail("provider-missing")
            if canonical(json.loads(got[1])) != canonical(expected_provider):
                return fail("provider-mismatch")
            if got[3] != item.get("notes") or canonical(json.loads(got[4] or "{}")) != canonical(item.get("meta", {})):
                return fail("provider-metadata-mismatch")
            if bool(got[2]) != (item["id"] == current_id):
                return fail("selection-mismatch")
        current_rows = db.execute(
            "SELECT id FROM providers WHERE app_type='claude' AND is_current=1"
        ).fetchall()
        if len(current_rows) != 1 or current_rows[0][0] != current_id:
            return fail("selection-mismatch")
        actual_settings = read_settings(os.path.join(stage_root_for_db(db_path),
                                                     "harness", "cc-switch", "claude", "settings.json"))
        if canonical(actual_settings) != canonical(expected_settings):
            return fail("settings-mismatch")
        emit(True, "verified", count=len(rows), current_id=current_id)
        return 0
    except Exception:
        return fail("verify")
    finally:
        if db is not None:
            db.close()


def main():
    if len(sys.argv) != 3:
        return fail("arguments")
    action, db_path = sys.argv[1], os.path.abspath(sys.argv[2])
    try:
        if action == "inspect":
            return inspect(db_path)
        payload = read_json_stdin()
        if action == "apply":
            return apply(db_path, payload)
        if action == "verify":
            return verify(db_path, payload)
        return fail("arguments")
    except RuntimeError as exc:
        return fail(str(exc))
    except Exception as exc:
        return fail("input-" + type(exc).__name__)


if __name__ == "__main__":
    sys.exit(main())
