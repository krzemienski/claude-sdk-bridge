# claude-sdk-bridge

A small TypeScript Model Context Protocol (MCP) server template. It speaks JSON-RPC over stdio in fewer than 30 lines of dispatcher code, ships three working tools, and includes a roundtrip test you can run before wiring it into Claude Code.

## Why this exists

This repo is the companion code for [post 24 of the *Agentic Development* series, *Custom MCP Servers*](https://withagents.dev/posts/post-24-custom-mcp-servers). The post argues that when no prebuilt MCP server fits, writing your own takes an afternoon. This is the working template referenced from that post: dispatcher, handler shape, tool catalog, and a signed-webhook example that demonstrates the env-only-secrets pattern.

Read the post for context. Use this repo to start.

## What's in here

| Path | Purpose |
| --- | --- |
| `src/mcp-server.ts` | 28-line stdio dispatcher: line-delimited JSON-RPC over stdin/stdout |
| `src/handlers.ts` | `initialize`, `tools/list`, `tools/call` method handlers |
| `src/tools.ts` | Tool catalog with JSON Schema input definitions |
| `src/sign-webhook.ts` | Envelope-pattern HMAC signer (env-only secrets) |
| `examples/mcp.json` | Registration manifest example for `~/.claude/mcp.json` |
| `scripts/test-roundtrip.sh` | Drives `initialize`, `tools/list`, `tools/call` and asserts responses |
| `dist/` | Pre-compiled JavaScript so the roundtrip test works without `tsc` |
| `.validation/run-1.log` | Captured output from a real run |

## Install

You need Node 18 or higher. Then:

```bash
git clone https://github.com/krzemienski/claude-sdk-bridge.git
cd claude-sdk-bridge
npm install        # installs typescript and the optional supabase client
```

If you only want to run the roundtrip test, you can skip `npm install` entirely. The pre-compiled output in `dist/` uses Node built-ins only.

## Quickstart: roundtrip test

```bash
bash scripts/test-roundtrip.sh
```

Expected last line of output:

```
Roundtrip test prints all 3 method responses with valid jsonrpc fields and non-empty results
```

The script writes three JSON-RPC requests into a file, pipes them into `node dist/mcp-server.js` over stdin, and validates each response. Each response must be a `{ jsonrpc: "2.0", id, result }` shape with a non-empty result body. The captured run lives at `.validation/run-1.log`.

## Quickstart: register with Claude Code

Build to `dist/` (or use the pre-built version), then add an entry to `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "supabase-views": {
      "command": "node",
      "args": ["/absolute/path/to/claude-sdk-bridge/dist/mcp-server.js"],
      "env": {
        "SUPABASE_URL": "${SUPABASE_URL}",
        "SUPABASE_SERVICE_KEY": "${SUPABASE_SERVICE_KEY}",
        "WEBHOOK_KEY_DEFAULT": "${WEBHOOK_KEY_DEFAULT}"
      }
    }
  }
}
```

A copy of that file lives at `examples/mcp.json`. Restart Claude Code, then run `/mcp`. The server appears with three tools.

## Tool catalog

| Tool | Required input | Output |
| --- | --- | --- |
| `supabase_view_query` | `view_name`, `user_id` (optional `limit`) | Rows from a view, scoped by `user_id` |
| `supabase_view_describe` | `view_name` | Schema info via the `describe_view` RPC |
| `sign_webhook` | `payload` (optional `key_id`, `algorithm`) | Signature envelope plus the signed message |

The Supabase tools require `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` set in env, plus the optional `@supabase/supabase-js` dependency installed.

The `sign_webhook` tool is the one the roundtrip test exercises. It demonstrates the envelope pattern: secrets never come in tool args, only key references. The signer resolves the reference against `process.env.WEBHOOK_KEY_<KEY_ID>` and falls back to a deterministic dev key when the env var is absent.

## Build from source

```bash
npm install
npx tsc            # writes dist/*.js
```

The TypeScript source compiles to CommonJS so it runs on plain Node without an ESM loader. The `dist/` directory in this repo is the output of `npx tsc` against the source you see. If you change anything in `src/`, rebuild before running the roundtrip test against your changes.

## How the dispatcher works

The whole protocol fits on one screen:

1. Read a line from stdin.
2. `JSON.parse` it as a JSON-RPC request.
3. Look up the method in the `HANDLERS` table.
4. Call the handler. Write the response as a single line to stdout.
5. Anything else (logs, errors, debug prints) goes to stderr so it never pollutes the protocol.

The tool catalog and the handlers are split into their own files so adding a new tool means appending one entry to `tools.ts` and one branch to `handleToolsCall` in `handlers.ts`. Nothing else moves.

## Why the envelope pattern

The `sign_webhook` tool is small but important as a reference. MCP tool args are visible to the model; sensitive secrets such as HMAC keys, API keys, and signing keys must never travel through them. The pattern in `sign-webhook.ts`:

1. Tool input takes a `key_id` (a string identifier), never a secret.
2. The handler resolves `WEBHOOK_KEY_<KEY_ID>` from `process.env`.
3. If absent, the signer falls back to a deterministic dev key so the demo works without configuration.
4. The response includes a `secret_source` field so the caller can see whether a real secret or the dev fallback was used.

Use the same shape any time a tool needs to hold credential material outside of the conversation context.

## Failure modes I have hit

- `console.log` in a handler corrupts the protocol; the client closes silently. All non-protocol output goes to stderr.
- A tool that takes more than ~30 seconds is killed by the client. For long jobs, return a job id and add a separate polling tool.
- Schema drift: changing a tool's params without bumping `inputSchema` causes the client to reject valid calls. Bump the schema first, code second.

## License

MIT. See `LICENSE`.
