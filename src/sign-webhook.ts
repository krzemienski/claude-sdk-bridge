/**
 * Envelope-pattern webhook signer. Secrets are resolved from env by key id;
 * they never travel through tool args. Useful as a reference for any MCP
 * tool that must hold sensitive material outside the conversation.
 */
import { createHmac, randomBytes } from "crypto";

export interface SignWebhookArgs {
  payload: Record<string, unknown>;
  keyId: string;
  algorithm: "sha256" | "sha512";
}

export interface SignWebhookResult {
  envelope: {
    timestamp: number;
    nonce: string;
    key_id: string;
    algorithm: string;
  };
  signature: string;
  signed_message: string;
  secret_source: string;
}

export function signWebhook({ payload, keyId, algorithm }: SignWebhookArgs): SignWebhookResult {
  const envName = `WEBHOOK_KEY_${keyId.toUpperCase()}`;
  const fromEnv = process.env[envName];
  const secret = fromEnv ?? deriveDevKey(keyId);

  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = randomBytes(8).toString("hex");
  const body = JSON.stringify(payload);
  const message = `${timestamp}.${nonce}.${body}`;
  const signature = createHmac(algorithm, secret).update(message).digest("hex");

  return {
    envelope: { timestamp, nonce, key_id: keyId, algorithm },
    signature,
    signed_message: message,
    secret_source: fromEnv ? `env:${envName}` : "derived-dev-key"
  };
}

function deriveDevKey(keyId: string): string {
  return createHmac("sha256", "claude-sdk-bridge-dev").update(keyId).digest("hex");
}
