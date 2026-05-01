/**
 * Pre-compiled output of src/handlers.ts (CommonJS).
 */
"use strict";
const { TOOLS } = require("./tools.js");
const { signWebhook } = require("./sign-webhook.js");

async function handleInitialize() {
  return {
    protocolVersion: "2024-11-05",
    capabilities: { tools: { listChanged: false } },
    serverInfo: { name: "supabase-views", version: "0.1.0" }
  };
}

async function handleToolsList() {
  return { tools: TOOLS };
}

async function handleToolsCall(params) {
  const { name, arguments: args = {} } = params || {};

  if (name === "sign_webhook") {
    const payload = args.payload || {};
    const keyId = args.key_id || "default";
    const algorithm = args.algorithm || "sha256";
    const result = signWebhook({ payload, keyId, algorithm });
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }

  if (name === "supabase_view_query") {
    return querySupabaseView(args);
  }

  if (name === "supabase_view_describe") {
    return describeSupabaseView(args);
  }

  return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
}

async function loadSupabase() {
  try {
    const mod = await import("@supabase/supabase-js");
    return mod.createClient;
  } catch {
    return null;
  }
}

function envCredentials() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) {
    return { error: "SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in env." };
  }
  return { url, key };
}

async function querySupabaseView(args) {
  const creds = envCredentials();
  if (creds.error) {
    return { content: [{ type: "text", text: creds.error }], isError: true };
  }
  const createClient = await loadSupabase();
  if (!createClient) {
    return {
      content: [{ type: "text", text: "Install @supabase/supabase-js to use this tool." }],
      isError: true
    };
  }
  const supabase = createClient(creds.url, creds.key);
  const { data, error } = await supabase
    .from(String(args.view_name))
    .select("*")
    .eq("user_id", String(args.user_id))
    .limit(typeof args.limit === "number" ? args.limit : 50);
  if (error) {
    return { content: [{ type: "text", text: `Error: ${error.message}` }], isError: true };
  }
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

async function describeSupabaseView(args) {
  const creds = envCredentials();
  if (creds.error) {
    return { content: [{ type: "text", text: creds.error }], isError: true };
  }
  const createClient = await loadSupabase();
  if (!createClient) {
    return {
      content: [{ type: "text", text: "Install @supabase/supabase-js to use this tool." }],
      isError: true
    };
  }
  const supabase = createClient(creds.url, creds.key);
  const { data, error } = await supabase.rpc("describe_view", { view_name: String(args.view_name) });
  if (error) {
    return { content: [{ type: "text", text: `Error: ${error.message}` }], isError: true };
  }
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

const HANDLERS = {
  initialize: handleInitialize,
  "tools/list": handleToolsList,
  "tools/call": handleToolsCall,
  shutdown: async () => ({})
};

module.exports = { HANDLERS, handleInitialize, handleToolsList, handleToolsCall };
