/**
 * Pre-compiled output of src/sign-webhook.ts (CommonJS).
 */
"use strict";
const { createHmac, randomBytes } = require("crypto");

function signWebhook({ payload, keyId, algorithm }) {
  const envName = `WEBHOOK_KEY_${String(keyId).toUpperCase()}`;
  const fromEnv = process.env[envName];
  const secret = fromEnv != null ? fromEnv : deriveDevKey(keyId);

  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = randomBytes(8).toString("hex");
  const body = JSON.stringify(payload);
  const message = `${timestamp}.${nonce}.${body}`;
  const signature = createHmac(algorithm, secret).update(message).digest("hex");

  return {
    envelope: { timestamp, nonce, key_id: keyId, algorithm },
    signature,
    signed_message: message,
    secret_source: fromEnv != null ? `env:${envName}` : "derived-dev-key"
  };
}

function deriveDevKey(keyId) {
  return createHmac("sha256", "claude-sdk-bridge-dev").update(keyId).digest("hex");
}

module.exports = { signWebhook };
