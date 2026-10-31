#!/usr/bin/env python3
"""ASHENFALL: UFA content package tool.

Commands:
  build   <src_dir> [--out dist] [--key tools/keys/dev_private.pem] [--no-sign]
          Builds a package from a source folder containing manifest.json
          (template: id, name, type, version, ...) plus data/, assets/,
          scripts/, locale/. Computes checksums, signs, publishes it into the
          distribution tree and regenerates catalog.json.
  catalog [--out dist]
          Regenerates dist/catalog.json from published packages.
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
ALLOWED_TOP = {"data", "assets", "scripts", "locale"}
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


def cmd_build(args) -> int:
    src = Path(args.src).resolve()
    out = Path(args.out).resolve()
    tmpl = json.loads((src / "manifest.json").read_text(encoding="utf-8"))
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
        return 1
    m = dict(tmpl)
    m.setdefault("api_version", 1)
    m.setdefault("data_format", 1)
    m.setdefault("min_game_version", "0.1.0")
    m["files"] = files
    m["size"] = sum(f["size"] for f in files)
    m["released"] = m.get("released") or dt.date.today().isoformat()
    if not args.no_sign:
        sign(m, Path(args.key))
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
          f"{', signed' if 'signature' in m else ', UNSIGNED'} -> {dest}")
    return cmd_catalog(args)


def vkey(v: str):
    return tuple(int(x) for x in (v.split("-")[0].split("+")[0].split(".") + ["0", "0"])[:3])


def cmd_catalog(args) -> int:
    out = Path(args.out).resolve()
    pk_root = out / "packages"
    entries = []
    if pk_root.exists():
        for pid in sorted(p for p in pk_root.iterdir() if p.is_dir()):
            versions = sorted((v for v in pid.iterdir() if (v / "manifest.json").exists()), key=lambda v: vkey(v.name))
            if not versions:
                continue
            latest = versions[-1]
            m = json.loads((latest / "manifest.json").read_text(encoding="utf-8"))
            entries.append({
                "id": m["id"], "name": m["name"], "type": m["type"], "version": m["version"],
                "description": m.get("description", ""), "author": m.get("author", ""),
                "size": m.get("size", 0), "min_game_version": m.get("min_game_version", "0.1.0"),
                "dependencies": m.get("dependencies", {}), "changelog": m.get("changelog", ""),
                "released": m.get("released", ""),
                "manifest": f"packages/{m['id']}/{m['version']}/manifest.json",
                "files_base": f"packages/{m['id']}/{m['version']}/files",
                "zip": f"packages/{m['id']}/{m['version']}/{m['id']}-{m['version']}.zip",
                "versions": [v.name for v in versions],
            })
    catalog = {"format": 1, "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "packages": entries}
    out.mkdir(parents=True, exist_ok=True)
    (out / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"catalog: {len(entries)} packages -> {out / 'catalog.json'}")
    return 0


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
    b = sub.add_parser("build")
    b.add_argument("src")
    b.add_argument("--out", default=str(ROOT / "dist"))
    b.add_argument("--key", default=str(ROOT / "tools" / "keys" / "dev_private.pem"))
    b.add_argument("--no-sign", action="store_true")
    c = sub.add_parser("catalog")
    c.add_argument("--out", default=str(ROOT / "dist"))
    s = sub.add_parser("serve")
    s.add_argument("--out", default=str(ROOT / "dist"))
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--host", default="0.0.0.0")
    v = sub.add_parser("verify")
    v.add_argument("manifest")
    args = ap.parse_args()
    return {"build": cmd_build, "catalog": cmd_catalog, "serve": cmd_serve, "verify": cmd_verify}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
