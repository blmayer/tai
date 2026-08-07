#!/usr/bin/env python3
"""Minimal local MCP server (stdio, JSON-RPC 2.0) for Tai tests.
Implements initialize, tools/list, tools/call. No list_changed/roots/sampling.
"""
import json
import sys


TOOLS = [
    {
        "name": "echo",
        "description": "Echo back the text argument",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": "Add two numbers a + b",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "number"},
                "b": {"type": "number"},
            },
            "required": ["a", "b"],
        },
    },
    {
        "name": "secret_tool",
        "description": "Should be denylisted in tests",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def respond(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    params = msg.get("params") or {}

    # Notifications (no id) — ignore
    if msg_id is None:
        return

    if method == "initialize":
        respond(
            msg_id,
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "dummy-mcp", "version": "0.1.0"},
            },
        )
    elif method == "tools/list":
        respond(msg_id, {"tools": TOOLS})
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "echo":
            text = args.get("text", "")
            respond(
                msg_id,
                {"content": [{"type": "text", "text": f"echo:{text}"}], "isError": False},
            )
        elif name == "add":
            a = float(args.get("a", 0))
            b = float(args.get("b", 0))
            respond(
                msg_id,
                {
                    "content": [{"type": "text", "text": str(a + b)}],
                    "isError": False,
                },
            )
        elif name == "secret_tool":
            respond(
                msg_id,
                {"content": [{"type": "text", "text": "secret-ok"}], "isError": False},
            )
        else:
            respond(
                msg_id,
                error={"code": -32601, "message": f"Unknown tool: {name}"},
            )
    elif method == "ping":
        respond(msg_id, {})
    else:
        respond(
            msg_id,
            error={"code": -32601, "message": f"Method not found: {method}"},
        )


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(msg)


if __name__ == "__main__":
    main()
