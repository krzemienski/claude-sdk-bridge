/**
 * MCP method handlers: initialize, tools/list, tools/call.
 * Supabase client is loaded lazily so the dispatcher boots without env or deps.
 */
import { TOOLS } from "./tools";
import { signWebhook } from "./sign-webhook";

interface ToolsCallParams {
  name: string;
  arguments?: Record<string, unknown>;
}

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
}

export async function handleInitialize(_params: unknown) {
  return {
    protocolVersion: "2024-11-05",
    capabilities: { tools: { listChanged: false } },
    serverInfo: { name: "supabase-views", version: "0.1.0" }
  };
}

export async function handleToolsList(_params: unknown) {
  return { tools: TOOLS };
}

export async function handleToolsCall(params: unknown): Promise<ToolResult> {
  const { name, arguments: args = {} } = (params ?? {}) as ToolsCallParams;

  if (name === "sign_webhook") {
    const payload = (args.payload as Record<string, unknown>) ?? {};
    const keyId = (args.key_id as string) ?? "default";
    const algorithm = ((args.algorithm as string) ?? "sha256") as "sha256" | "sha512";
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

async function loadSupabase(): Promise<((url: string, key: string) => any) | null> {
  try {
    const mod: any = await import("@supabase/supabase-js");
    return mod.createClient as (url: string, key: string) => any;
  } catch {
    return null;
  }
}

function envCredentials(): { url: string; key: string } | { error: string } {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) {
    return { error: "SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in env." };
  }
  return { url, key };
}

async function querySupabaseView(args: Record<string, unknown>): Promise<ToolResult> {
  const creds = envCredentials();
  if ("error" in creds) {
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

async function describeSupabaseView(args: Record<string, unknown>): Promise<ToolResult> {
  const creds = envCredentials();
  if ("error" in creds) {
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

export const HANDLERS: Record<string, (params: unknown) => Promise<unknown>> = {
  initialize: handleInitialize,
  "tools/list": handleToolsList,
  "tools/call": handleToolsCall,
  shutdown: async () => ({})
};
