#!/usr/bin/env python3
"""ASHENFALL: UFA content package tool.

Commands:
  build      <src_dir> [--version X] [--channel stable] [--no-publish] [--key K]
             Builds a package from a folder with manifest.json + data/ assets/
             scripts/ locale/, signs it, stores it under dist/packages and
             publishes it to a channel (catalog regenerated).
  build-code --pck game.pck --version X --engine 4.5.1 --min-apk-build N --key RELEASE_KEY
             Wraps an exported Godot .pck into the signed "game.core" package:
             the game code/data update that the APK mounts at startup.
  publish    <id> <version> [--channel C]   point a channel at a built version
  rollback   <id> [--to X] [--channel C]    point a channel back to an earlier version
  unpublish  <id> [--channel C]             remove a package from a channel
  prune      [--keep 3]                     delete old unreferenced versions
  status                                    show what each channel serves
  catalog                                   regenerate catalog*.json and index.html
  serve   [--out dist] [--port 8765] [--host 0.0.0.0]
          Development update server with HTTP Range support (resumable
          downloads). Production uses any static CDN/mirror with Range support.
  verify  <manifest.json>
          Verifies a manifest signature with every key in config/trusted_keys.

Distribution layout (what the game's update manager expects):
  dist/catalog.json
  dist/packages/<id>/<version>/manifest.json
  dist/packages/<id>/<version>/files/<relative path>
  dist/packages/<id>/<version>/<id>-<version>.zip
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import http.server
import json
import os
import re
import shutil
import socketserver
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TYPES = ["ENGINE", "SYSTEM", "REGION", "ASSET", "AUDIO", "QUEST", "LOCALIZATION", "MOD", "DLC"]
ALLOWED_EXT = {"json", "png", "jpg", "jpeg", "webp", "glb", "gltf", "bin", "ogg", "wav", "mp3",
               "md", "txt", "csv", "po", "ttf", "otf", "pck"}
ALLOWED_TOP = {"data", "assets", "scripts", "locale", "code"}
ALLOWED_ROOT = {"preview.png", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE.md", "LICENSE.txt"}
FORBIDDEN_EXT = {"gd", "gdc", "gde", "cs", "so", "dll", "dylib", "dex", "jar", "apk", "aab", "exe", "sh", "bat", "py", "js", "wasm"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.\-]{2,63}$")
PATH_RE = re.compile(r"^[A-Za-z0-9_\-./]+$")


def check_path(rel: str) -> str:
    """Python mirror of AfManifest.check_path()."""
    if not rel or len(rel) > 200:
        return "bad length"
    if rel.startswith("/") or "\\" in rel or ":" in rel:
        return f"absolute/invalid path: {rel}"
    if not PATH_RE.match(rel):
        return f"invalid characters: {rel}"
    segs = rel.split("/")
    if any(s in ("", ".", "..") for s in segs):
        return f"path traversal: {rel}"
    ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
    if ext in FORBIDDEN_EXT:
        return f"executable file not allowed: {rel}"
    if len(segs) == 1:
        return "" if rel in ALLOWED_ROOT else f"root file not allowed: {rel}"
    if segs[0] not in ALLOWED_TOP:
        return f"directory not allowed: {segs[0]}"
    if ext not in ALLOWED_EXT:
        return f"file type not allowed: {rel}"
    return ""


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def signing_payload(m: dict) -> str:
    """Python mirror of AfManifest.signing_payload()."""
    lines = ["ashenfall-package-v1", str(m.get("id", "")), str(m.get("version", "")), str(m.get("type", "")),
             str(m.get("min_game_version", ""))]
    deps = m.get("dependencies", {}) or {}
    for k in sorted(deps):
        lines.append(f"dep {k} {deps[k]}")
    entries = sorted(f"file {f['path']} {f['sha256'].lower()}" for f in m.get("files", []))
    lines.extend(entries)
    return "\n".join(lines)


def sign(m: dict, key_path: Path) -> None:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    sig = key.sign(signing_payload(m).encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
    m["signature"] = base64.b64encode(sig).decode("ascii")
    m["key_id"] = key_path.stem


def verify(m: dict) -> str:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    sig = base64.b64decode(m.get("signature", ""))
    for pem in sorted((ROOT / "config" / "trusted_keys").glob("*.pem")):
        pub = serialization.load_pem_public_key(pem.read_bytes())
        try:
            pub.verify(sig, signing_payload(m).encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
            return pem.stem
        except InvalidSignature:
            continue
    return ""


def _build_package(src: Path, out: Path, key: Path | None, version: str = "", extra: dict | None = None) -> dict | None:
    tmpl = json.loads((src / "manifest.json").read_text(encoding="utf-8"))
    if version:
        tmpl["version"] = version
    tmpl.update(extra or {})
    errors = []
    if not ID_RE.match(str(tmpl.get("id", ""))) or tmpl.get("id") == "core":
        errors.append("invalid id")
    if tmpl.get("type") not in TYPES:
        errors.append(f"invalid type {tmpl.get('type')}")
    if not re.match(r"^\d+(\.\d+){0,2}$", str(tmpl.get("version", ""))):
        errors.append("invalid version")
    files = []
    for p in sorted(src.rglob("*")):
        if p.is_dir() or p.name == "manifest.json" and p.parent == src:
            continue
        rel = p.relative_to(src).as_posix()
        why = check_path(rel)
        if why:
            errors.append(why)
            continue
        files.append({"path": rel, "sha256": sha256_file(p), "size": p.stat().st_size})
    if errors:
        print("build failed:\n  " + "\n  ".join(errors), file=sys.stderr)
        return None
    m = dict(tmpl)
    m.setdefault("api_version", 1)
    m.setdefault("data_format", 1)
    m.setdefault("min_game_version", "0.1.0")
    m["files"] = files
    m["size"] = sum(f["size"] for f in files)
    m["released"] = m.get("released") or dt.date.today().isoformat()
    if key is not None:
        sign(m, key)
    dest = out / "packages" / m["id"] / m["version"]
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "files").mkdir(parents=True)
    for f in files:
        target = dest / "files" / f["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src / f["path"], target)
    (dest / "manifest.json").write_text(json.dumps(m, ensure_ascii=False, indent=1), encoding="utf-8")
    zip_path = dest / f"{m['id']}-{m['version']}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(m, ensure_ascii=False, indent=1))
        for f in files:
            z.write(src / f["path"], f["path"])
    print(f"built {m['id']} {m['version']}: {len(files)} files, {m['size']} bytes"
          f"{', signed with ' + m['key_id'] if 'signature' in m else ', UNSIGNED'} -> {dest}")
    return m


def _key_arg(args) -> Path | None:
    if args.no_sign:
        return None
    return Path(args.key)


def cmd_build(args) -> int:
    out = Path(args.out).resolve()
    m = _build_package(Path(args.src).resolve(), out, _key_arg(args), args.version or "")
    if m is None:
        return 1
    if args.no_publish:
        return 0
    return _publish(out, m["id"], m["version"], args.channel)


def cmd_build_code(args) -> int:
    """Packages an exported Godot .pck as the signed game-code package."""
    import tempfile
    out = Path(args.out).resolve()
    pck = Path(args.pck).resolve()
    if not pck.exists():
        print(f"no such pck: {pck}", file=sys.stderr)
        return 1
    if Path(args.key).name.startswith("dev_") and not args.allow_dev_key:
        print("code packages must be signed with a release key (dev keys are never trusted for code)", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp)
        (src / "code").mkdir()
        shutil.copy2(pck, src / "code" / "game.pck")
        (src / "manifest.json").write_text(json.dumps({
            "id": "game.core", "name": "ASHENFALL: UFA — код игры", "type": "SYSTEM",
            "version": args.version, "engine": args.engine, "min_apk_build": args.min_apk_build,
            "min_game_version": "0.0.0", "author": "Ashenfall Team",
            "description": "Скрипты, сцены и данные ядра. Подключается при запуске игры поверх кода из APK.",
            "changelog": args.changelog or "",
        }, ensure_ascii=False), encoding="utf-8")
        m = _build_package(src, out, Path(args.key))
    if m is None:
        return 1
    return 0 if args.no_publish else _publish(out, m["id"], m["version"], args.channel)


# --- release management -----------------------------------------------------------

def vkey(v: str):
    return tuple(int(x) for x in (v.split("-")[0].split("+")[0].split(".") + ["0", "0"])[:3])


def _versions_on_disk(out: Path, pid: str) -> list[str]:
    d = out / "packages" / pid
    if not d.exists():
        return []
    return sorted((v.name for v in d.iterdir() if (v / "manifest.json").exists()), key=vkey)


def _load_releases(out: Path) -> dict:
    p = out / "releases.json"
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    # first run on an older tree: publish the newest version of everything to stable
    rel = {"channels": {"stable": {}}, "history": []}
    pk = out / "packages"
    if pk.exists():
        for pid in sorted(x.name for x in pk.iterdir() if x.is_dir()):
            vs = _versions_on_disk(out, pid)
            if vs:
                rel["channels"]["stable"][pid] = vs[-1]
    return rel


def _save_releases(out: Path, rel: dict) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "releases.json").write_text(json.dumps(rel, ensure_ascii=False, indent=1), encoding="utf-8")


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def _publish(out: Path, pid: str, version: str, channel: str, action: str = "publish") -> int:
    if version not in _versions_on_disk(out, pid):
        print(f"{pid} {version} is not built in {out}", file=sys.stderr)
        return 1
    rel = _load_releases(out)
    prev = rel["channels"].setdefault(channel, {}).get(pid)
    rel["channels"][channel][pid] = version
    rel["history"].append({"at": _now(), "channel": channel, "id": pid, "version": version, "previous": prev, "action": action})
    _save_releases(out, rel)
    print(f"{action}: {pid} {prev or '-'} -> {version} [{channel}]")
    return _write_catalogs(out)


def cmd_publish(args) -> int:
    return _publish(Path(args.out).resolve(), args.id, args.version, args.channel)


def cmd_rollback(args) -> int:
    """Points a channel back to an earlier published version (files stay on the server)."""
    out = Path(args.out).resolve()
    rel = _load_releases(out)
    cur = rel["channels"].get(args.channel, {}).get(args.id)
    target = args.to
    if not target:
        for h in reversed(rel["history"]):
            if h["channel"] == args.channel and h["id"] == args.id and h["version"] != cur and h["version"] in _versions_on_disk(out, args.id):
                target = h["version"]
                break
    if not target:
        print("no earlier version to roll back to", file=sys.stderr)
        return 1
    return _publish(out, args.id, target, args.channel, "rollback")


def cmd_unpublish(args) -> int:
    out = Path(args.out).resolve()
    rel = _load_releases(out)
    prev = rel["channels"].get(args.channel, {}).pop(args.id, None)
    rel["history"].append({"at": _now(), "channel": args.channel, "id": args.id, "version": None, "previous": prev, "action": "unpublish"})
    _save_releases(out, rel)
    return _write_catalogs(out)


def cmd_prune(args) -> int:
    """Deletes old versions that no channel references, keeping the newest N."""
    out = Path(args.out).resolve()
    rel = _load_releases(out)
    used = {(pid, v) for ch in rel["channels"].values() for pid, v in ch.items()}
    removed = 0
    pk = out / "packages"
    for pid in (sorted(x.name for x in pk.iterdir() if x.is_dir()) if pk.exists() else []):
        vs = _versions_on_disk(out, pid)
        for v in vs[:-args.keep] if args.keep > 0 else vs:
            if (pid, v) not in used:
                shutil.rmtree(pk / pid / v)
                removed += 1
    print(f"pruned {removed} old versions")
    return _write_catalogs(out)


def cmd_status(args) -> int:
    out = Path(args.out).resolve()
    rel = _load_releases(out)
    for ch, pkgs in rel["channels"].items():
        print(f"[{ch}]")
        for pid, v in sorted(pkgs.items()):
            print(f"  {pid:28} {v:10} (on server: {', '.join(_versions_on_disk(out, pid))})")
    return 0


def _catalog_entry(out: Path, pid: str, version: str) -> dict | None:
    mp = out / "packages" / pid / version / "manifest.json"
    if not mp.exists():
        return None
    m = json.loads(mp.read_text(encoding="utf-8"))
    return {
        "id": m["id"], "name": m["name"], "type": m["type"], "version": m["version"],
        "description": m.get("description", ""), "author": m.get("author", ""),
        "size": m.get("size", 0), "min_game_version": m.get("min_game_version", "0.1.0"),
        "dependencies": m.get("dependencies", {}), "changelog": m.get("changelog", ""),
        "released": m.get("released", ""), "engine": m.get("engine", ""), "min_apk_build": m.get("min_apk_build", 0),
        "manifest": f"packages/{m['id']}/{m['version']}/manifest.json",
        "files_base": f"packages/{m['id']}/{m['version']}/files",
        "zip": f"packages/{m['id']}/{m['version']}/{m['id']}-{m['version']}.zip",
        "versions": _versions_on_disk(out, pid),
    }


def _write_catalogs(out: Path) -> int:
    rel = _load_releases(out)
    _save_releases(out, rel)
    rel["channels"].setdefault("stable", {})
    rows = []
    for ch, pkgs in rel["channels"].items():
        entries = [e for e in (_catalog_entry(out, pid, v) for pid, v in sorted(pkgs.items())) if e]
        catalog = {"format": 1, "channel": ch, "generated_at": _now(), "packages": entries}
        name = "catalog.json" if ch == "stable" else f"catalog-{ch}.json"
        (out / name).write_text(json.dumps(catalog, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"catalog [{ch}]: {len(entries)} packages -> {out / name}")
        rows += [f"<tr><td>{ch}</td><td>{e['id']}</td><td>{e['name']}</td><td>{e['version']}</td><td>{e['size']}</td><td>{e['released']}</td></tr>" for e in entries]
    (out / ".nojekyll").write_text("")
    (out / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>ASHENFALL: UFA updates</title>"
        "<style>body{font:15px sans-serif;background:#14161a;color:#e6e1d8;padding:24px}td,th{padding:4px 10px;text-align:left}</style>"
        f"<h1>ASHENFALL: UFA — сервер обновлений</h1><p>Обновлено: {_now()}</p>"
        "<table><tr><th>Канал</th><th>ID</th><th>Пакет</th><th>Версия</th><th>Байт</th><th>Дата</th></tr>"
        + "".join(rows) + "</table>" + _apk_links(out), encoding="utf-8")
    return 0


def _apk_links(out: Path) -> str:
    apk_dir = out / "apk"
    if not apk_dir.exists():
        return ""
    apks = sorted(apk_dir.glob("*.apk"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not apks:
        return ""
    items = "".join(f'<li><a style="color:#f2c27b" href="apk/{a.name}">{a.name}</a> ({a.stat().st_size // 1048576} МБ)</li>' for a in apks)
    return ("<h2>Установка на Android</h2><p>APK нужен один раз. Дальше игра обновляется сама при запуске.</p>"
            f"<ul>{items}</ul>")


def cmd_catalog(args) -> int:
    return _write_catalogs(Path(args.out).resolve())


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    """Static file handler with single-range support (bytes=N- / bytes=N-M)."""

    def log_message(self, fmt, *a):
        if os.environ.get("AFPKG_QUIET") != "1":
            super().log_message(fmt, *a)

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.exists(path):
            return super().send_head()
        rng = self.headers.get("Range")
        size = os.path.getsize(path)
        if not rng:
            return super().send_head()
        m = re.match(r"bytes=(\d+)-(\d*)$", rng.strip())
        if not m:
            self.send_error(400, "bad range")
            return None
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else size - 1
        if start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        end = min(end, size - 1)
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self._range_left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        left = getattr(self, "_range_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        while left > 0:
            chunk = source.read(min(65536, left))
            if not chunk:
                break
            outputfile.write(chunk)
            left -= len(chunk)


def cmd_serve(args) -> int:
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    handler = lambda *a, **kw: RangeHandler(*a, directory=str(out), **kw)
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer((args.host, args.port), handler) as httpd:
        print(f"serving {out} on http://{args.host}:{args.port}", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


def cmd_verify(args) -> int:
    m = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    key = verify(m)
    print(f"signature OK ({key})" if key else "signature INVALID or missing")
    return 0 if key else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    default_out = str(ROOT / "dist")
    default_key = os.environ.get("AF_SIGNING_KEY_FILE", str(ROOT / "tools" / "keys" / "dev_private.pem"))

    def common(p, key=False, channel=False):
        p.add_argument("--out", default=default_out)
        if key:
            p.add_argument("--key", default=default_key)
            p.add_argument("--no-sign", action="store_true")
        if channel:
            p.add_argument("--channel", default="stable")
        return p

    b = common(sub.add_parser("build"), key=True, channel=True)
    b.add_argument("src")
    b.add_argument("--version", default="")
    b.add_argument("--no-publish", action="store_true")
    bc = common(sub.add_parser("build-code"), key=True, channel=True)
    bc.add_argument("--pck", required=True)
    bc.add_argument("--version", required=True)
    bc.add_argument("--engine", required=True)
    bc.add_argument("--min-apk-build", type=int, required=True)
    bc.add_argument("--changelog", default="")
    bc.add_argument("--no-publish", action="store_true")
    bc.add_argument("--allow-dev-key", action="store_true", help=argparse.SUPPRESS)
    pb = common(sub.add_parser("publish"), channel=True)
    pb.add_argument("id")
    pb.add_argument("version")
    rb = common(sub.add_parser("rollback"), channel=True)
    rb.add_argument("id")
    rb.add_argument("--to", default="")
    up = common(sub.add_parser("unpublish"), channel=True)
    up.add_argument("id")
    pr = common(sub.add_parser("prune"))
    pr.add_argument("--keep", type=int, default=3)
    common(sub.add_parser("status"))
    common(sub.add_parser("catalog"))
    s = common(sub.add_parser("serve"))
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--host", default="0.0.0.0")
    v = sub.add_parser("verify")
    v.add_argument("manifest")
    args = ap.parse_args()
    return {"build": cmd_build, "build-code": cmd_build_code, "publish": cmd_publish, "rollback": cmd_rollback,
            "unpublish": cmd_unpublish, "prune": cmd_prune, "status": cmd_status, "catalog": cmd_catalog,
            "serve": cmd_serve, "verify": cmd_verify}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
