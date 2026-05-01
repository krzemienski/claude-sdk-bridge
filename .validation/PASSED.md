# Validation: PASSED

- **Date:** 2026-04-30
- **Command:** `bash scripts/test-roundtrip.sh > .validation/run-1.log 2>&1`
- **Iterations to pass:** 1
- **Exit code:** 0

## Proof of expectation

Last lines of `.validation/run-1.log`:

```
[roundtrip] all 3 responses validated (initialize + tools/list + tools/call)
Roundtrip test prints all 3 method responses with valid jsonrpc fields and non-empty results
```

The literal expected sentence — `Roundtrip test prints all 3 method responses with valid jsonrpc fields and non-empty results` — appears as the final line of the captured run.

## Response shape evidence

Each of the three JSON-RPC responses captured in `run-1.log`:

- **id 1 (initialize):** `result.protocolVersion = "2024-11-05"`, `result.serverInfo = { name: "supabase-views", version: "0.1.0" }`, `result.capabilities.tools.listChanged = false`
- **id 2 (tools/list):** `result.tools` contains 3 entries (`supabase_view_query`, `supabase_view_describe`, `sign_webhook`), each with `inputSchema`
- **id 3 (tools/call sign_webhook):** `result.content[0].text` contains a JSON document with non-empty `signature` (`f22902fc4bc64d66dc44b70b161fba487b9b327aae6989ca241cc35c8d9f33d4`), `envelope`, `signed_message`, and `secret_source = "derived-dev-key"`

All three responses have `jsonrpc = "2.0"` and a non-empty `result` body. None carries an `error` field.

## Files in the repo

```
.gitignore
LICENSE
README.md
dist/handlers.js
dist/mcp-server.js
dist/sign-webhook.js
dist/tools.js
examples/mcp.json
package.json
scripts/test-roundtrip.sh
src/handlers.ts
src/mcp-server.ts
src/sign-webhook.ts
src/tools.ts
tsconfig.json
.validation/run-1.log
.validation/PASSED.md
```

## Total line count

`wc -l` over all source, dist, scripts, examples, config, README, and LICENSE (excluding fixtures and `.validation/`):

```
   45 src/mcp-server.ts
  119 src/handlers.ts
   60 src/tools.ts
   46 src/sign-webhook.ts
   42 dist/mcp-server.js
  111 dist/handlers.js
   65 dist/tools.js
   31 dist/sign-webhook.js
  110 scripts/test-roundtrip.sh
   13 examples/mcp.json
   25 package.json
   17 tsconfig.json
  119 README.md
   21 LICENSE
   13 .gitignore
  ----
  827 total
```

**Total lines of code (no fixtures, no validation logs): 827**
