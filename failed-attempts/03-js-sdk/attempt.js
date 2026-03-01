/**
 * Attempt 3: JavaScript SDK (@anthropic-ai/sdk)
 *
 * The npm package had its own authentication issues and added a Node.js
 * runtime to the dependency chain for no clear benefit over the Python SDK.
 *
 * This approach was abandoned in favor of the Python Agent SDK wrapper
 * which provides cleaner async iteration and inherits Claude Code's OAuth.
 */

import Anthropic from "@anthropic-ai/sdk";

/**
 * Stream a response from Claude using the JavaScript SDK.
 *
 * This requires ANTHROPIC_API_KEY, which is not available in a Claude Code
 * environment. The SDK does not support Claude Code's OAuth token chain.
 *
 * Even if authentication worked, this adds Node.js as a runtime dependency
 * when the backend is already Swift/Vapor. The Python SDK (claude-agent-sdk)
 * provides the same functionality with a cleaner integration path since it
 * wraps the Claude CLI directly and inherits its authentication.
 *
 * @param {string} prompt - The user's message
 * @returns {Promise<string>} The full response text
 */
async function streamResponse(prompt) {
  // Fails immediately: ANTHROPIC_API_KEY not set in Claude Code env
  const client = new Anthropic();

  let fullText = "";

  const stream = await client.messages.stream({
    model: "claude-sonnet-4-20250514",
    max_tokens: 4096,
    messages: [{ role: "user", content: prompt }],
  });

  for await (const event of stream) {
    if (
      event.type === "content_block_delta" &&
      event.delta.type === "text_delta"
    ) {
      const text = event.delta.text;
      fullText += text;
      process.stdout.write(text);
    }
  }

  return fullText;
}

/**
 * Alternative: Use the Claude Agent SDK for Node.js.
 *
 * Even this approach has issues when spawned from within a Claude Code
 * session due to environment variable inheritance (CLAUDECODE=1 triggers
 * nesting detection in the underlying CLI call).
 */
async function streamWithAgentSDK(prompt) {
  // The @anthropic-ai/claude-agent-sdk npm package wraps the CLI
  // but inherits the parent process environment, including CLAUDECODE=1
  const { query } = await import("@anthropic-ai/claude-agent-sdk");

  const stream = query({
    prompt,
    options: {
      include_partial_messages: true,
    },
  });

  for await (const message of stream) {
    if (message.type === "assistant") {
      for (const block of message.content) {
        if (block.type === "text") {
          process.stdout.write(block.text);
        }
      }
    }
  }
}

// Main execution
const prompt = process.argv[2] || "Say hello";
console.log(`Attempting to stream response for: "${prompt}"\n`);

streamResponse(prompt).catch((error) => {
  console.error(`\nFailed: ${error.message}`);
  console.error(
    "The JavaScript SDK requires ANTHROPIC_API_KEY which is not " +
      "available in Claude Code's OAuth environment."
  );
  process.exit(1);
});
