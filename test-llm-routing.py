#!/usr/bin/env python3
"""
LLM routing pre-flight test.

Answers three questions required to clear the blockers in
litellm-proxy-deployment-v0.1.md and llm-routing-config-v0.1.md:

  Q1  Does `claude` forward an unknown model string verbatim to the
      endpoint, or does it replace it with a known Anthropic model ID?
      (Non-transparent routing via model-alias depends on verbatim forwarding.)

  Q2a Does `claude` include an Authorization header when ANTHROPIC_BASE_URL
      is overridden? (Transparent routing depends on the token being forwarded.)

  Q2b Does Anthropic's API accept the forwarded token?
      (Determines whether transparent Anthropic routing is viable at all.)

Usage:
  python3 test-llm-routing.py

  Or on a remote host:
  ssh chrisrobertson@192.168.1.81 'python3 -' < test-llm-routing.py

Requires: `claude` CLI in PATH, outbound HTTPS to api.anthropic.com.
No external Python packages needed.
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


# ---------------------------------------------------------------------------
# Local echo server
# ---------------------------------------------------------------------------

def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


_captured = {}


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
        except Exception:
            data = {}

        _captured["model"] = data.get("model", "")
        _captured["auth"] = self.headers.get("Authorization", "")
        _captured["path"] = self.path
        _captured["got_request"] = True

        # Return a minimal valid Anthropic response so claude doesn't error.
        resp = json.dumps({
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "ok"}],
            "model": data.get("model", "unknown"),
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 5, "output_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, fmt, *args):
        pass  # suppress access log noise


def _start_echo_server():
    port = _free_port()
    srv = http.server.HTTPServer(("127.0.0.1", port), _Handler)
    t = threading.Thread(target=srv.serve_forever)
    t.daemon = True
    t.start()
    return srv, port


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
SKIP = "\033[33mSKIP\033[0m"


def _token_safe(auth_header):
    """Return a safe-to-print prefix of an Authorization header."""
    if not auth_header:
        return "(none)"
    # Show type + first 6 chars of token value — enough to confirm presence
    parts = auth_header.split(" ", 1)
    if len(parts) == 2:
        return f"{parts[0]} {parts[1][:6]}..."
    return auth_header[:12] + "..."


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print()
    print("=" * 64)
    print("LLM ROUTING PRE-FLIGHT TEST")
    print("=" * 64)

    # Check claude is available
    if subprocess.run(["which", "claude"], capture_output=True).returncode != 0:
        print("\nERROR: `claude` not found in PATH. Run this on a host with Claude Code installed.")
        sys.exit(1)

    srv, port = _start_echo_server()
    base_url = f"http://127.0.0.1:{port}"
    print(f"\nEcho server: {base_url}")
    time.sleep(0.1)  # let server bind

    # -----------------------------------------------------------------------
    # Stage 1 — model alias forwarding
    # -----------------------------------------------------------------------
    print("\n── Stage 1: model alias forwarding ──────────────────────────")
    print(f"  ANTHROPIC_BASE_URL={base_url}")
    print(f"  claude -p 'say hi' --model explore-class")

    env = os.environ.copy()
    env["ANTHROPIC_BASE_URL"] = base_url

    try:
        result = subprocess.run(
            ["claude", "-p", "say hi", "--model", "explore-class"],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        print("\n  ERROR: claude timed out after 30s")
        srv.shutdown()
        sys.exit(1)

    if not _captured.get("got_request"):
        print("\n  ERROR: echo server received no request.")
        print(f"  claude stdout: {result.stdout[:300]}")
        print(f"  claude stderr: {result.stderr[:300]}")
        srv.shutdown()
        sys.exit(1)

    model_sent = _captured["model"]
    auth_sent = _captured["auth"]

    print(f"\n  model field in request: {model_sent!r}")
    if model_sent == "explore-class":
        q1 = True
        print(f"  {PASS}  Q1: forwarded verbatim — non-transparent routing works")
    else:
        q1 = False
        print(f"  {FAIL}  Q1: replaced with {model_sent!r} — non-transparent routing broken")
        print("         Claude Code validates model strings before sending.")
        print("         See llm-routing-config-v0.1.md §7 Blocker #1 for fallback options.")

    # -----------------------------------------------------------------------
    # Stage 2a — auth header presence
    # -----------------------------------------------------------------------
    print("\n── Stage 2a: auth header forwarding ─────────────────────────")
    print(f"  Authorization header received: {_token_safe(auth_sent)}")

    if auth_sent:
        q2a = True
        print(f"  {PASS}  Q2a: token forwarded to proxy")
    else:
        q2a = False
        print(f"  {FAIL}  Q2a: no Authorization header — transparent Anthropic routing cannot work")

    # -----------------------------------------------------------------------
    # Stage 2b — Anthropic API acceptance
    # -----------------------------------------------------------------------
    print("\n── Stage 2b: Anthropic API token acceptance ─────────────────")
    if not q2a:
        q2b = None
        print(f"  {SKIP}  no token to test")
    else:
        payload = json.dumps({
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 5,
            "messages": [{"role": "user", "content": "hi"}],
        }).encode()
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=payload,
            headers={
                "Authorization": auth_sent,
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                status = resp.status
                body = json.loads(resp.read())
            q2b = True
            print(f"  HTTP {status} — accepted")
            print(f"  Response model: {body.get('model', '?')}")
            print(f"  {PASS}  Q2b: Anthropic accepts forwarded token — transparent routing works")
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")
            try:
                err = json.loads(body_text).get("error", {})
                err_msg = f"{err.get('type', '?')}: {err.get('message', body_text[:120])}"
            except Exception:
                err_msg = body_text[:120]
            q2b = False
            print(f"  HTTP {e.code} — rejected")
            print(f"  {err_msg}")
            print(f"  {FAIL}  Q2b: Anthropic API rejects subscription token")
            print("         Transparent Anthropic routing is not viable.")
            print("         Anthropic calls must bypass LiteLLM (go direct to api.anthropic.com).")
        except Exception as e:
            q2b = None
            print(f"  ERROR: {e}")

    srv.shutdown()

    # -----------------------------------------------------------------------
    # Summary + routing outcome
    # -----------------------------------------------------------------------
    print()
    print("=" * 64)
    print("SUMMARY")
    print("=" * 64)
    print(f"  Q1  model alias verbatim:          {PASS if q1 else FAIL}")
    print(f"  Q2a auth header forwarded:         {PASS if q2a else FAIL}")
    q2b_label = (PASS if q2b else FAIL) if q2b is not None else SKIP
    print(f"  Q2b Anthropic accepts token:       {q2b_label}")
    print()

    if q1 and q2b:
        print("OUTCOME: fully unblocked.")
        print("  Transparent mode:     ANTHROPIC_BASE_URL routes both Anthropic + Ollama")
        print("  Non-transparent mode: model alias in subagent frontmatter routes to Ollama")
        print()
        print("NEXT: promote litellm-proxy-deployment-v0.1.md and llm-routing-config-v0.1.md")
        print("      to status: draft and begin implementation.")

    elif q1 and q2b is False:
        print("OUTCOME: non-transparent Ollama routing unblocked; transparent Anthropic blocked.")
        print("  Subagents declaring `model: explore-class` (etc.) route to Ollama correctly.")
        print("  Anthropic calls must go direct — LiteLLM sits in front of Ollama only.")
        print()
        print("NEXT: update litellm-proxy-deployment-v0.1.md §3.3 to document this outcome.")
        print("      Remove the Anthropic upstream from the provider list.")
        print("      The spec can then be promoted to draft for Ollama-only transparent routing.")

    elif not q1 and q2b:
        print("OUTCOME: transparent routing works; non-transparent routing broken.")
        print("  ANTHROPIC_BASE_URL can route all calls through LiteLLM transparently.")
        print("  Model alias in subagent frontmatter is NOT forwarded — can't use for routing.")
        print()
        print("NEXT: update llm-routing-config-v0.1.md §7 Blocker #1.")
        print("      Fall back to virtual-key tags or per-request metadata for agent identity.")

    elif not q1 and q2b is False:
        print("OUTCOME: both blockers remain.")
        print("  Model alias is not forwarded; Anthropic token is not accepted.")
        print("  Only viable path: LiteLLM as Ollama-only router with virtual-key tags.")
        print()
        print("NEXT: revisit specs with the user before any implementation.")

    print()


if __name__ == "__main__":
    main()
