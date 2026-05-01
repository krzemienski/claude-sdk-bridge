/**
 * Pre-compiled output of src/tools.ts (CommonJS).
 */
"use strict";
const TOOLS = [
  {
    name: "supabase_view_query",
    description:
      "Query a Supabase view with row-level security context. Use when you need data from views that require user_id scope.",
    inputSchema: {
      type: "object",
      properties: {
        view_name: { type: "string", description: "Name of the view to query" },
        user_id: { type: "string", description: "User ID for RLS context" },
        limit: { type: "integer", default: 50, maximum: 500 }
      },
      required: ["view_name", "user_id"]
    }
  },
  {
    name: "supabase_view_describe",
    description: "Get the schema of a view including column types.",
    inputSchema: {
      type: "object",
      properties: {
        view_name: { type: "string" }
      },
      required: ["view_name"]
    }
  },
  {
    name: "sign_webhook",
    description:
      "Sign a webhook payload with HMAC. Resolves the secret from WEBHOOK_KEY_<KEY_ID> env so secrets never appear in tool args. Returns the signature envelope, signed message, and source.",
    inputSchema: {
      type: "object",
      properties: {
        payload: {
          type: "object",
          description: "JSON object to sign. Will be serialized deterministically."
        },
        key_id: {
          type: "string",
          default: "default",
          description: "Identifier resolved against WEBHOOK_KEY_<KEY_ID> env var"
        },
        algorithm: {
          type: "string",
          enum: ["sha256", "sha512"],
          default: "sha256"
        }
      },
      required: ["payload"]
    }
  }
];

module.exports = { TOOLS };
