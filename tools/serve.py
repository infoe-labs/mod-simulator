#!/usr/bin/env python3
"""Local test server for the web build and the AI lab.

    python3 tools/serve.py                     # http://127.0.0.1:8000/  (dist/)
    python3 tools/serve.py --dir game/web      # just the AI lab + ai/ modules
    python3 tools/serve.py --port 8080 --coi   # add COOP/COEP (SharedArrayBuffer)

Why the headers are what they are:

* `application/wasm` must be served with the right MIME type or the browser
  refuses to stream-compile it.
* `Cache-Control: no-store` means a rebuild is never hidden behind a cached
  .wasm - the classic "my change did nothing" bug.
* COOP/COEP are **off by default**: this game exports the single-threaded Web
  build (`variant/thread_support=false`), so it does not need SharedArrayBuffer,
  and requiring `cross-origin-resource-policy` on every response would break
  the model-weight download from the Hugging Face CDN used by AI Chat Mode.
  Pass `--coi` to reproduce a host that *does* send them.
"""
from __future__ import annotations
import argparse
import http.server
import os
import socketserver
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIST = os.path.normpath(os.path.join(HERE, "..", "dist"))


class Handler(http.server.SimpleHTTPRequestHandler):
    coi = True
    # So a re-run right after Ctrl-C doesn't fail with "address in use".
    allow_reuse_address = True

    def end_headers(self) -> None:  # noqa: N802
        if self.coi:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # Always fresh while iterating: no stale .wasm after a rebuild.
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

    def guess_type(self, path: str) -> str:
        if path.endswith(".wasm"):
            return "application/wasm"
        if path.endswith(".pck"):
            return "application/octet-stream"
        if path.endswith(".js") or path.endswith(".mjs"):
            return "text/javascript"
        if path.endswith(".wasm.metadata"):
            return "application/json"
        return super().guess_type(path)

    def log_message(self, fmt: str, *args) -> None:  # quieter
        sys.stderr.write("  %s\n" % (fmt % args))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", "--dir", dest="dist", default=DEFAULT_DIST)
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--coi", dest="coi", action="store_true", default=False,
                    help="send Cross-Origin-Opener/Embedder-Policy headers")
    ap.add_argument("--no-coi", dest="coi", action="store_false",
                    help="deprecated alias for the current default")
    a = ap.parse_args()
    if not os.path.isdir(a.dist):
        print(f"no such directory: {a.dist}  (run tools/export.sh first)", file=sys.stderr)
        return 2
    if not os.path.exists(os.path.join(a.dist, "index.html")):
        print(f"note: {a.dist} has no index.html (fine for the AI lab, not for the game)")
    os.chdir(a.dist)
    Handler.coi = a.coi
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((a.host, a.port), Handler) as httpd:
        url = f"http://{a.host}:{a.port}/"
        print(f"serving {a.dist}")
        print(f"  {url}")
        print(f"  cross-origin isolation: {'on' if Handler.coi else 'off (single-threaded build, and HF downloads need it off)'}")
        print("  Ctrl-C to stop")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
