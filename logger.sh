#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  logger.sh --logfile /path/to/log.txt --port 8080

Pipes stdin -> logfile (append) and serves:
  GET /logs?since=N&limit=M
    - since defaults to -1
    - limit defaults to 500 (max 5000)
Response JSON:
  { "next": <last_id_returned_or_since>, "lines": [ {"id":0,"content":"..."}, ... ] }
EOF
}

LOGFILE=""
PORT="8080"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logfile) LOGFILE="${2:-}"; shift 2;;
    --port)    PORT="${2:-}"; shift 2;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "${LOGFILE}" ]]; then
  echo "Missing --logfile" >&2
  usage
  exit 1
fi

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

python3 - "$LOGFILE" "$PORT" <<'PY' &
import sys, json, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

LOGFILE = sys.argv[1]
PORT = int(sys.argv[2])

lock = threading.Lock()

# Cache for the "likely next request" path (single-client assumption)
# Meaning: last request returned up through line last_next, and reading ended at last_pos.
cache = {
  "last_since": None,  # last requested since
  "last_pos": 0,       # byte offset after last served read
  "last_next": -1,     # last line id returned
}

def read_from_start(since: int, limit: int):
  """Fallback: scan from beginning until id > since."""
  out = []
  cur_id = -1
  with open(LOGFILE, "rb") as f:
    while True:
      raw = f.readline()
      if not raw:
        pos = f.tell()
        break
      cur_id += 1
      if cur_id <= since:
        continue
      line = raw.decode("utf-8", errors="replace").rstrip("\n")
      out.append({"id": cur_id, "content": line})
      if len(out) >= limit:
        pos = f.tell()
        break

  next_id = out[-1]["id"] if out else since
  return out, next_id, pos

def read_from_pos(start_pos: int, start_id: int, limit: int):
  """Fast path: resume from last byte offset and last id."""
  out = []
  cur_id = start_id
  with open(LOGFILE, "rb") as f:
    f.seek(start_pos)
    while True:
      raw = f.readline()
      if not raw:
        pos = f.tell()
        break
      cur_id += 1
      line = raw.decode("utf-8", errors="replace").rstrip("\n")
      out.append({"id": cur_id, "content": line})
      if len(out) >= limit:
        pos = f.tell()
        break

  next_id = out[-1]["id"] if out else start_id
  return out, next_id, pos

class Handler(BaseHTTPRequestHandler):
  def _send_json(self, code: int, payload: dict):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    self.send_response(code)
    self.send_header("Content-Type", "application/json; charset=utf-8")
    self.send_header("Access-Control-Allow-Origin", "*")
    self.end_headers()
    self.wfile.write(body)

  def do_GET(self):
    p = urlparse(self.path)
    if p.path == "/health":
      self.send_response(200)
      self.send_header("Content-Type", "text/plain; charset=utf-8")
      self.send_header("Access-Control-Allow-Origin", "*")
      self.end_headers()
      self.wfile.write(b"ok\n")
      return

    if p.path != "/logs":
      return self._send_json(404, {"error": "not found"})

    qs = parse_qs(p.query or "")
    try:
      since = int(qs.get("since", ["-1"])[0])
    except Exception:
      since = -1
    try:
      limit = int(qs.get("limit", ["500"])[0])
    except Exception:
      limit = 500
    if limit < 1: limit = 1
    if limit > 5000: limit = 5000

    # Decide fast path vs fallback
    with lock:
      last_next = cache["last_next"]
      last_pos = cache["last_pos"]

    if since == last_next:
      # Resume from last file position
      lines, next_id, pos = read_from_pos(last_pos, last_next, limit)
    else:
      # Different since: full scan
      lines, next_id, pos = read_from_start(since, limit)

    with lock:
      cache["last_since"] = since
      cache["last_next"] = next_id
      cache["last_pos"] = pos

    return self._send_json(200, {"next": next_id, "lines": lines})

  def log_message(self, fmt, *args):
    return

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY

SERVER_PID=$!
trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT

echo "logger.sh: writing to $LOGFILE" >&2
echo "logger.sh: serving http://0.0.0.0:$PORT/logs?since=N&limit=M" >&2

# Stream stdin -> logfile (append) and mirror to stderr
tee -a "$LOGFILE" | cat >&2
