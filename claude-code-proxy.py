#!/usr/bin/env python3
"""
claude-code-proxy — OpenAI-compatible API proxy that routes to `claude -p`.

Bridges Hermes Agent (requires OpenAI-compatible endpoint) with Claude Code
CLI (uses OAuth, no raw API key needed).

Usage:
    python3 claude-code-proxy.py <PORT> <FLEET_DIR> <REPO_PATH>

  PORT       local port (e.g. 9001)
  FLEET_DIR  fleet root; service-context.md is read from here on each request
  REPO_PATH  repo to expose to claude via --add-dir

In Hermes config.yaml:
    model:
      provider: custom
      base_url: http://127.0.0.1:9001/v1
      default: claude-code
"""

import json
import re
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from pathlib import Path

if len(sys.argv) < 4:
    print(f"usage: {sys.argv[0]} PORT FLEET_DIR REPO_PATH", file=sys.stderr)
    sys.exit(1)

PORT = int(sys.argv[1])
FLEET_DIR = Path(sys.argv[2]).expanduser().resolve()
REPO_PATH = Path(sys.argv[3]).expanduser().resolve()

# Tools the staff agents are allowed to invoke via claude -p.
# Patterns follow Claude Code --allowedTools syntax.
_ALLOWED_TOOLS = "Bash(gh *) Bash(git *) Bash(date *) Bash(echo *) Read Glob Grep"

_TOOL_PROTOCOL = """
TOOL CALLING PROTOCOL
When you need to call a tool output exactly this (nothing else on the line):
<tool>{"name":"TOOL_NAME","args":ARGS_JSON}</tool>
When you have a final answer write normal text with no <tool> block.
"""


def _service_context() -> str:
    p = FLEET_DIR / "service-context.md"
    return p.read_text() if p.exists() else ""


def _tool_defs_text(tools: list) -> str:
    lines = ["AVAILABLE TOOLS:"]
    for t in tools:
        if t.get("type") == "function":
            fn = t["function"]
            props = fn.get("parameters", {}).get("properties", {})
            lines.append(f"- {fn['name']}: {fn.get('description', '')} args={list(props)}")
    return "\n".join(lines)


def _format_conversation(messages: list) -> str:
    parts = []
    for m in messages:
        role = m.get("role", "user")
        content = m.get("content") or ""
        if isinstance(content, list):
            content = " ".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        if role == "user":
            parts.append(f"Human: {content}")
        elif role == "assistant":
            parts.append(f"Assistant: {content}")
        elif role == "tool":
            parts.append(f"Tool result ({m.get('name', 'tool')}): {content}")
    return "\n\n".join(parts)


def _call_claude(append_system: str, conversation: str) -> str:
    cmd = [
        "claude", "-p",
        "--model", "claude-sonnet-4-6",
        "--add-dir", str(REPO_PATH),
        "--allowedTools", _ALLOWED_TOOLS,
    ]
    if append_system:
        # --append-system-prompt preserves Claude's default tool knowledge;
        # --system-prompt would replace it (breaking tool use entirely).
        cmd += ["--append-system-prompt", append_system]

    r = subprocess.run(cmd, input=conversation, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"claude -p exited {r.returncode}")
    return r.stdout.strip()


def _parse_tool_call(text: str) -> dict | None:
    m = re.search(r"<tool>(.*?)</tool>", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    return None


def _completions(body: dict) -> dict:
    messages = body.get("messages", [])
    tools = body.get("tools", [])

    system_parts = [m["content"] for m in messages if m.get("role") == "system"]
    conv_msgs = [m for m in messages if m.get("role") != "system"]

    extras = []
    ctx = _service_context()
    if ctx:
        extras.append(f"SERVICE CONTEXT:\n{ctx}")
    if tools:
        extras.append(_tool_defs_text(tools))
        extras.append(_TOOL_PROTOCOL)

    # All system content appended to Claude's default prompt (preserves tool defs).
    append_system = "\n\n".join(filter(None, system_parts + extras))
    response = _call_claude(append_system, _format_conversation(conv_msgs))

    tool_call = _parse_tool_call(response) if tools else None

    if tool_call:
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": tool_call["name"],
                    "arguments": json.dumps(tool_call.get("args", {})),
                },
            }],
        }
        finish = "tool_calls"
    else:
        message = {"role": "assistant", "content": response}
        finish = "stop"

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:8]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": body.get("model", "claude-code"),
        "choices": [{"index": 0, "message": message, "finish_reason": finish}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


class _ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _json(self, status: int, data: dict):
        payload = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/health", "/v1/health"):
            self._json(200, {"status": "ok", "fleet": str(FLEET_DIR), "repo": str(REPO_PATH)})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path not in ("/v1/chat/completions", "/chat/completions"):
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n))
        try:
            self._json(200, _completions(body))
        except Exception as e:
            self._json(500, {"error": {"message": str(e), "type": "server_error"}})


if __name__ == "__main__":
    srv = _ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    print(
        f"claude-code-proxy  port={PORT}  fleet={FLEET_DIR}  repo={REPO_PATH}",
        flush=True,
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
