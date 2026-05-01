#!/usr/bin/env bash
# Roundtrip check: pipes initialize, tools/list, tools/call into the
# stdio dispatcher and confirms each response is a valid JSON-RPC 2.0
# message with a non-empty result body. Drives the real running server
# binary over stdin/stdout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST="dist/mcp-server.js"
if [[ ! -f "$DIST" ]]; then
  echo "[roundtrip] missing $DIST -- run: npx tsc"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[roundtrip] node not on PATH"
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() {
  if [[ -d "$WORK" ]]; then
    find "$WORK" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

REQ_FILE="$WORK/requests.jsonl"
OUT_FILE="$WORK/responses.jsonl"
ERR_FILE="$WORK/server-stderr.log"

cat > "$REQ_FILE" <<'INNER_EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sign_webhook","arguments":{"payload":{"event":"roundtrip.run","value":42},"key_id":"default","algorithm":"sha256"}}}
INNER_EOF

echo "[roundtrip] requests:"
cat "$REQ_FILE"
echo ""

# Drive the stdio dispatcher over pipes. The same line-delimited JSON
# framing works identically across nc-style sockets and stdin/stdout.
node "$DIST" < "$REQ_FILE" > "$OUT_FILE" 2> "$ERR_FILE" || true

echo "[roundtrip] server stderr:"
if [[ -s "$ERR_FILE" ]]; then
  sed 's/^/  /' "$ERR_FILE"
else
  echo "  (empty)"
fi
echo ""

echo "[roundtrip] raw responses:"
sed 's/^/  /' "$OUT_FILE"
echo ""

node - "$OUT_FILE" <<'NODE_EOF'
const fs = require("fs");
const path = process.argv[2];
const text = fs.readFileSync(path, "utf8");
const lines = text.split("\n").filter((l) => l.trim().startsWith("{"));
if (lines.length < 3) {
  console.error(`FAIL: expected >=3 response lines, got ${lines.length}`);
  process.exit(1);
}

let seenInit = false;
let seenList = false;
let seenCall = false;
for (const line of lines) {
  const obj = JSON.parse(line);
  if (obj.jsonrpc !== "2.0") {
    console.error("FAIL: bad or missing jsonrpc field on:", line);
    process.exit(1);
  }
  if (obj.error) {
    console.error("FAIL: response carries error:", JSON.stringify(obj.error));
    process.exit(1);
  }
  if (!obj.result || (typeof obj.result === "object" && Object.keys(obj.result).length === 0)) {
    console.error("FAIL: empty result on:", line);
    process.exit(1);
  }
  const r = obj.result;
  if (obj.id === 1 && typeof r.protocolVersion === "string" && r.serverInfo) seenInit = true;
  if (obj.id === 2 && Array.isArray(r.tools) && r.tools.length >= 3) seenList = true;
  if (
    obj.id === 3 &&
    Array.isArray(r.content) &&
    r.content.length > 0 &&
    typeof r.content[0].text === "string" &&
    r.content[0].text.length > 0
  ) {
    const inner = JSON.parse(r.content[0].text);
    if (typeof inner.signature === "string" && inner.signature.length > 0) seenCall = true;
  }
}

if (!seenInit || !seenList || !seenCall) {
  console.error(`FAIL: seenInit=${seenInit} seenList=${seenList} seenCall=${seenCall}`);
  process.exit(1);
}
console.log("[roundtrip] all 3 responses validated (initialize + tools/list + tools/call)");
NODE_EOF

echo "Roundtrip test prints all 3 method responses with valid jsonrpc fields and non-empty results"
