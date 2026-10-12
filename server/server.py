"""Single-vault encrypted configuration sync. Run behind HTTPS for remote use."""

import base64
import binascii
import hashlib
import hmac
import json
import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 1_400_000
ALGORITHM = "PBKDF2-SHA256+AES-256-GCM"


class Conflict(Exception):
    pass


def validate_envelope(value):
    if not isinstance(value, dict) or set(value) != {
        "version", "algorithm", "iterations", "salt", "ciphertext"
    }:
        raise ValueError("Invalid encrypted envelope")
    if type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("Unsupported version")
    if value["algorithm"] != ALGORITHM or type(value["iterations"]) is not int or value["iterations"] != 600_000:
        raise ValueError("Unsupported encryption parameters")
    try:
        salt = base64.b64decode(value["salt"], validate=True)
        ciphertext = base64.b64decode(value["ciphertext"], validate=True)
    except (ValueError, TypeError, binascii.Error):
        raise ValueError("Invalid base64") from None
    if len(salt) != 16 or not 28 <= len(ciphertext) <= 1_000_000:
        raise ValueError("Invalid encrypted payload length")


class VaultStore:
    def __init__(self, path):
        self.path = str(path)
        Path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE IF NOT EXISTS vault (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, payload TEXT NOT NULL)")
        os.chmod(path, 0o600)

    def connect(self):
        return sqlite3.connect(self.path, timeout=10)

    def read(self):
        with self.connect() as db:
            row = db.execute("SELECT revision, payload FROM vault WHERE id=1").fetchone()
        return {"revision": row[0], "payload": json.loads(row[1])} if row else {"revision": 0, "payload": None}

    def write(self, revision, payload):
        if type(revision) is not int or not 0 <= revision < 2**53:
            raise ValueError("Invalid revision")
        validate_envelope(payload)
        serialized = json.dumps(payload, separators=(",", ":"))
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM vault WHERE id=1").fetchone()
            current = row[0] if row else 0
            if revision != current:
                raise Conflict()
            db.execute("INSERT INTO vault(id, revision, payload) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload",
                       (current + 1, serialized))
        return {"revision": current + 1, "payload": payload}


class SyncServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, store, token):
        if len(token) < 32 or any(c.isspace() for c in token):
            raise ValueError("VOICEDRAFT_SYNC_TOKEN must have at least 32 characters and no whitespace")
        self.store = store
        self.token_digest = hashlib.sha256(token.encode()).digest()
        super().__init__(address, SyncHandler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


class SyncHandler(BaseHTTPRequestHandler):
    server_version = "VoiceDraftSync/1"
    sys_version = ""

    def log_message(self, format, *args):
        # Do not log tokens, request bodies, URLs, or ciphertext.
        pass

    def reply(self, code, body):
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            self.reply(401, {"error": "Unauthorized"})
            return False
        provided = hashlib.sha256(header[7:].encode()).digest()
        if not hmac.compare_digest(provided, self.server.token_digest):
            self.reply(401, {"error": "Unauthorized"})
            return False
        return True

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"status": "ok", "protocol": 1})
            return
        if not self.authorized():
            return
        if self.path != "/v1/sync":
            self.reply(404, {"error": "Not found"})
            return
        try:
            self.reply(200, self.server.store.read())
        except sqlite3.Error:
            self.reply(503, {"error": "Storage unavailable"})

    def do_PUT(self):
        if not self.authorized():
            return
        if self.path != "/v1/sync":
            self.reply(404, {"error": "Not found"})
            return
        if self.headers.get_content_type() != "application/json":
            self.reply(415, {"error": "Use application/json"})
            return
        if self.headers.get("Transfer-Encoding"):
            self.reply(400, {"error": "Chunked uploads are not supported"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                self.reply(413, {"error": "Invalid request size"})
                return
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError("Incomplete body")
            body = json.loads(data)
            if not isinstance(body, dict) or set(body) != {"revision", "payload"}:
                raise ValueError("Expected revision and encrypted payload")
            self.reply(200, self.server.store.write(body["revision"], body["payload"]))
        except Conflict:
            self.reply(409, {"error": "Revision conflict; fetch before retrying"})
        except (ValueError, TypeError, UnicodeError):
            self.reply(400, {"error": "Invalid request or encrypted envelope"})
        except (TimeoutError, OSError):
            self.close_connection = True
        except sqlite3.Error:
            self.reply(503, {"error": "Storage unavailable"})


def main():
    os.umask(0o077)
    token = os.environ.get("VOICEDRAFT_SYNC_TOKEN", "")
    database = os.environ.get("VOICEDRAFT_DB", "./data/vault.sqlite3")
    host = os.environ.get("VOICEDRAFT_HOST", "127.0.0.1")
    port = int(os.environ.get("VOICEDRAFT_PORT", "8765"))
    server = SyncServer((host, port), VaultStore(database), token)
    print(f"VoiceDraft sync listening on {host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
