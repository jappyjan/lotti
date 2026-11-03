#!/usr/bin/env python3
"""A stand-in for Hermes's API server, for trying Lotti's connector without a Hermes.

Speaks /v1/chat/completions with SSE streaming, like Hermes: a tool-progress event, keepalive
comments, content deltas. The first turn of a question asks for two phone tools at once
(calendar and weather); once the results are in, it answers with a timer action.

Like Hermes, it keeps sessions: with an `X-Hermes-Session-Id` header it holds that session's turns
itself and uses only the last message of the body as the new turn (earlier messages in the body
are ignored). Answers say how many earlier questions the session has seen, so a follow-up shows
the history continued. Without the header it is stateless. `GET /v1/capabilities` advertises
`session_continuity_header`, and `POST /v1/runs/{id}/stop` answers "stopping".

    python3 scripts/mock-hermes.py [port]      # default 8642, key "test"
    HERMES_URL=http://127.0.0.1:8642 HERMES_KEY=test HERMES_MOCK=1 swift test --filter LiveHermes
"""
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = "test"

# session id -> the turns Hermes would hold in its state.db (the new message of every request)
SESSIONS = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {KEY}":
            return True
        self.reply(401, {"error": {"message": "Invalid API key"}})
        return False

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/v1/health"):
            return self.reply(200, {"status": "ok"})
        if self.path in ("/v1/models", "/v1/capabilities") and not self.authorized():
            return
        if self.path == "/v1/models":
            return self.reply(200, {"object": "list", "data": [{"id": "hermes-agent", "object": "model"}]})
        if self.path == "/v1/capabilities":
            return self.reply(200, {"object": "capabilities", "session_continuity_header": "X-Hermes-Session-Id",
                                    "features": {"chat_completions": True, "streaming": True, "run_stop": True}})
        self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.authorized():
            return
        stop = re.fullmatch(r"/v1/runs/([^/]+)/stop", self.path)
        if stop:  # the mock answers at once, so there is never anything left to stop
            return self.reply(200, {"run_id": stop.group(1), "status": "stopping"})
        if self.path != "/v1/chat/completions":
            return self.reply(404, {"error": {"message": "not found"}})
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        last = body["messages"][-1]["content"]
        session = self.headers.get("X-Hermes-Session-Id")
        history = SESSIONS.setdefault(session, []) if session else []
        # Questions of this session before the current one (results messages belong to a question).
        earlier = sum(1 for turn in history if '"type":"results"' not in turn)
        if '"type":"results"' in last:
            earlier = max(0, earlier - 1)  # the question this round belongs to is already in the history
        history.append(last)
        if '"type":"results"' in last:
            results = json.loads(last)["results"]
            facts = " / ".join(r["content"].split("\n")[0] for r in results)
            text = json.dumps({
                "type": "answer",
                "sentence": f"Mock Hermes ({earlier} earlier question{'' if earlier == 1 else 's'}) saw: {facts}"[:150],
                "followUps": ["Thanks"],
                "actions": [{"tool": "set_timer", "args": {"minutes": 10, "label": "Tea"}}],
            })
        else:
            text = json.dumps({
                "type": "call",
                "status": "Checking your day",
                "calls": [
                    {"id": "c1", "tool": "calendar", "args": {"from": "tomorrow"}},
                    {"id": "c2", "tool": "weather", "args": {}},
                ],
            })
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b": keepalive\n\n")
        self.wfile.write(b'event: hermes.tool.progress\ndata: {"tool":"web_search","label":"Searching the web"}\n\n')
        completion = f"chatcmpl-{uuid.uuid4().hex[:29]}"  # also the run id, as at Hermes
        for i in range(0, len(text), 20):
            chunk = {"id": completion, "object": "chat.completion.chunk",
                     "choices": [{"index": 0, "delta": {"content": text[i:i + 20]}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8642
    print(f"mock Hermes on http://127.0.0.1:{port}, key {KEY!r}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
