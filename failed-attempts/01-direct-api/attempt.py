"""
Attempt 1: Direct Anthropic API Call

The obvious first approach — import the SDK, pass the API key, stream the response.
Three lines of meaningful code. Dead on arrival.

Claude Code authenticates through OAuth, not API keys. There is no
ANTHROPIC_API_KEY environment variable to read. Users would need to
create one through the Anthropic console, which defeats the purpose
of building a client for Claude Code — authentication must flow
through Claude Code's own credential chain.
"""

import anthropic
import asyncio


async def stream_response(prompt: str) -> str:
    """
    Attempt to stream a response from the Anthropic API directly.

    This requires ANTHROPIC_API_KEY, which Claude Code does not provide.
    Claude Code uses OAuth browser-based authentication, and the resulting
    session tokens are managed internally by the CLI — not exposed to
    third-party consumers.

    Raises:
        anthropic.AuthenticationError: Always, because no API key is available
            when running under Claude Code's OAuth authentication.
    """
    # This instantiation fails because ANTHROPIC_API_KEY is not set
    # in a Claude Code environment. The SDK checks for the env var
    # and raises AuthenticationError immediately.
    client = anthropic.Anthropic()

    collected_text = ""

    # Even if we got past authentication, this would work fine —
    # the streaming API itself is well-designed. The problem is
    # purely at the authentication layer.
    with client.messages.stream(
        model="claude-sonnet-4-20250514",
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    ) as stream:
        for text in stream.text_stream:
            collected_text += text
            print(text, end="", flush=True)

    return collected_text


def main():
    """Run the direct API attempt. Will fail with AuthenticationError."""
    import sys

    prompt = sys.argv[1] if len(sys.argv) > 1 else "Say hello"

    try:
        result = asyncio.run(stream_response(prompt))
        print(f"\n\nFull response: {result}")
    except anthropic.AuthenticationError as e:
        print(f"\nAuthentication failed: {e}", file=sys.stderr)
        print(
            "Claude Code uses OAuth, not API keys. "
            "ANTHROPIC_API_KEY is not available.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
