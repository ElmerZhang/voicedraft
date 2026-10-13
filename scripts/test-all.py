#!/usr/bin/env python3
"""Run Swift/Python tests against an isolated local server, without real model calls."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from server import SyncHandler, SyncServer, VaultStore


class IntegrationHandler(SyncHandler):
    def do_POST(self):
        if self.path.startswith("/mock/stream/"):
            adapter = self.path.rsplit("/", 1)[-1]
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["stream"] is True
            if adapter == "anthropic":
                assert self.headers.get("x-api-key") == "test-only-key"
                events = [
                    {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "你好"}},
                    {"type": "content_block_delta", "delta": {"type": "text_delta", "text": " VoiceDraft"}},
                    {"type": "message_delta", "delta": {"stop_reason": "end_turn"}},
                    {"type": "message_stop"},
                ]
            elif adapter == "responses":
                assert body["store"] is False
                events = [
                    {"type": "response.output_text.delta", "delta": "你好"},
                    {"type": "response.output_text.delta", "delta": " VoiceDraft"},
                    {"type": "response.completed", "response": {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "你好 VoiceDraft"}]}]}},
                ]
            else:
                events = [{"choices": [{"delta": {"content": "你好"}}]}]
                if adapter != "truncated":
                    events += [{"choices": [{"delta": {"content": " VoiceDraft"}, "finish_reason": "stop"}]}]
            wire = "".join("data: " + json.dumps(event, ensure_ascii=False) + "\n\n" for event in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            # Split inside multibyte UTF-8 and JSON/SSE boundaries.
            for offset in range(0, len(wire), 7):
                self.wfile.write(wire[offset:offset+7]); self.wfile.flush()
            return
        if self.path == "/mock/redirect":
            self.send_response(307)
            self.send_header("Location", "/mock/leaked")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/mock/leaked":
            self.server.leaked = True
            self.reply(500, {})
            return
        if self.path == "/mock/rate-limit":
            self.reply(429, {"error": {"message": "test-only-key"}})
            return
        if self.path != "/mock/qwen" or self.headers.get("Authorization") != "Bearer test-only-key":
            self.reply(401, {})
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body["model"] == "qwen3-asr-flash":
            content = body["messages"][-1]["content"][0]
            if content.get("type") != "input_audio" or not content["input_audio"]["data"].startswith("data:audio/wav;base64,"):
                self.reply(400, {})
                return
            text = "We should ship VoiceDraft tomorrow."
        else:
            content = json.loads(body["messages"][-1]["content"])
            if content["transcript"] != "We should ship VoiceDraft tomorrow.":
                self.reply(400, {})
                return
            text = "Ship VoiceDraft tomorrow."
        self.reply(200, {"choices": [{"message": {"content": text}, "finish_reason": "stop"}]})


def main():
    os.chdir(ROOT)
    subprocess.run([sys.executable, "scripts/check-localizations.py"], check=True)
    subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "server", "-v"], check=True)
    with tempfile.TemporaryDirectory(prefix="voicedraft-test-") as directory:
        token = secrets.token_urlsafe(32)
        server = SyncServer(("127.0.0.1", 0), VaultStore(Path(directory) / "vault.sqlite3"), token)
        server.RequestHandlerClass = IntegrationHandler
        server.leaked = False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = os.environ.copy()
        environment.update({
            "VOICEDRAFT_TEST_SERVER": f"http://127.0.0.1:{server.server_port}",
            "VOICEDRAFT_TEST_TOKEN": token,
            "CLANG_MODULE_CACHE_PATH": str(ROOT / ".build/clang-cache"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(ROOT / ".build/swift-cache"),
        })
        try:
            subprocess.run(["swift", "test", "--disable-sandbox"], env=environment, check=True)
            assert not server.leaked, "The client followed a credential-bearing redirect"
            print("All checks passed, including encrypted two-device sync and simulated Qwen / multi-provider writing streams.")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
