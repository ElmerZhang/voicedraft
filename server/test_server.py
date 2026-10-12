import base64
import concurrent.futures
import http.client
import json
from pathlib import Path
import secrets
import tempfile
import threading
import unittest

from server import ALGORITHM, SyncServer, VaultStore


def envelope():
    return {"version": 1, "algorithm": ALGORITHM, "iterations": 600_000,
            "salt": base64.b64encode(secrets.token_bytes(16)).decode(),
            "ciphertext": base64.b64encode(secrets.token_bytes(100)).decode()}


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "vault.sqlite3"
        self.token = secrets.token_urlsafe(32)
        self.server = SyncServer(("127.0.0.1", 0), VaultStore(self.path), self.token)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, method="GET", body=None, token=None, path="/v1/sync", headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        request_headers = {"Authorization": "Bearer " + (self.token if token is None else token),
                           "Content-Type": "application/json"}
        if headers:
            request_headers.update(headers)
        connection.request(method, path, json.dumps(body).encode() if body is not None else None, request_headers)
        response = connection.getresponse()
        code, data = response.status, json.loads(response.read())
        connection.close()
        return code, data

    def test_auth_required_and_health_is_public(self):
        self.assertEqual(self.request(token="wrong")[0], 401)
        self.assertEqual(self.request("PUT", {"revision": 0, "payload": envelope()}, token="wrong")[0], 401)
        self.assertEqual(self.request(token="", path="/healthz")[0], 200)
        self.assertEqual(self.request()[1], {"revision": 0, "payload": None})

    def test_two_device_round_trip_and_persistence(self):
        payload = envelope()
        self.assertEqual(self.request("PUT", {"revision": 0, "payload": payload})[0], 200)
        code, downloaded = self.request()
        self.assertEqual(code, 200)
        self.assertEqual(downloaded, {"revision": 1, "payload": payload})
        self.assertEqual(VaultStore(self.path).read(), downloaded)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_stale_write_cannot_overwrite_newer_device(self):
        first, second = envelope(), envelope()
        self.request("PUT", {"revision": 0, "payload": first})
        self.assertEqual(self.request("PUT", {"revision": 0, "payload": second})[0], 409)
        self.assertEqual(self.request()[1]["payload"], first)
        self.assertEqual(self.request("PUT", {"revision": 1, "payload": second})[1]["revision"], 2)

    def test_concurrent_updates_have_one_winner(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.request("PUT", {"revision": 0, "payload": envelope()})[0], range(8)))
        self.assertEqual(results.count(200), 1)
        self.assertEqual(results.count(409), 7)

    def test_plaintext_and_malformed_envelopes_are_rejected(self):
        cases = [None, {"apiKey": "must-not-be-stored"}, {**envelope(), "apiKey": "secret"},
                 {**envelope(), "iterations": 1}, {**envelope(), "salt": "invalid"},
                 {**envelope(), "version": True}, {**envelope(), "ciphertext": "AA=="}]
        for payload in cases:
            with self.subTest(payload=payload):
                self.assertEqual(self.request("PUT", {"revision": 0, "payload": payload})[0], 400)
        self.assertEqual(self.request()[1]["revision"], 0)

    def test_bad_revision_and_request_limits(self):
        for revision in [-1, True, "0", 2**60]:
            self.assertEqual(self.request("PUT", {"revision": revision, "payload": envelope()})[0], 400)
        self.assertEqual(self.request("PUT", {}, headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("PUT", {}, headers={"Content-Length": "1400001"})[0], 413)
        self.assertEqual(self.request(path="/v1/sync?token=ignored")[0], 404)


if __name__ == "__main__":
    unittest.main()
