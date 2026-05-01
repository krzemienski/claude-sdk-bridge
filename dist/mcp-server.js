#!/usr/bin/env node
/**
 * Pre-compiled output of src/mcp-server.ts (CommonJS).
 * MCP stdio dispatcher: line-delimited JSON-RPC over stdin/stdout.
 */
"use strict";
const { createInterface } = require("readline");
const { HANDLERS } = require("./handlers.js");

const rl = createInterface({ input: process.stdin, terminal: false });

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function log(...args) {
  process.stderr.write("[mcp] " + args.map(String).join(" ") + "\n");
}

rl.on("line", async (line) => {
  if (!line.trim()) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch (e) {
    log("bad json:", line);
    return;
  }
  const handler = HANDLERS[req.method || ""];
  if (!handler) {
    send({ jsonrpc: "2.0", id: req.id ?? null, error: { code: -32601, message: "method not found" } });
    return;
  }
  try {
    const result = await handler(req.params ?? {});
    send({ jsonrpc: "2.0", id: req.id ?? null, result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    send({ jsonrpc: "2.0", id: req.id ?? null, error: { code: -32603, message } });
  }
});
