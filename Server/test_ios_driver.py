import hashlib
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import unittest


SERVER = Path(__file__).with_name("ios_driver.py")
TOKEN = "a" * 64


def packet(filename, data_type=1, payload=b"image", sequence=0, last=1, size=None):
    name = filename.encode()
    return (bytes([len(name)]) + name
            + struct.pack(">BIIB", data_type, len(payload) if size is None else size, sequence, last)
            + payload)


class ServerIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        cls.cert = cls.directory / "cert.pem"
        cls.key = cls.directory / "key.pem"
        cls.token_file = cls.directory / "token"
        cls.token_file.write_text(TOKEN)
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=localhost", "-keyout", str(cls.key), "-out", str(cls.cert)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        cls.fingerprint = hashlib.sha256(
            ssl.PEM_cert_to_DER_cert(cls.cert.read_text())
        ).digest()
        cls.server = subprocess.Popen(
            [sys.executable, "-u", str(SERVER), "--port", "0", "--cert", str(cls.cert),
             "--key", str(cls.key), "--token-file", str(cls.token_file)],
            cwd=cls.directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        line = cls.server.stdout.readline()
        if not line.startswith("[*] Server listening on 127.0.0.1:"):
            cls.server.terminate()
            cls.server.wait()
            cls.temp.cleanup()
            raise RuntimeError(f"server did not start: {line}")
        cls.port = int(line.rsplit(":", 1)[1])

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)
        cls.server.stdout.close()
        cls.temp.cleanup()

    def connect(self, token=TOKEN, fingerprint=None):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        client = context.wrap_socket(raw, server_hostname="localhost")
        if hashlib.sha256(client.getpeercert(binary_form=True)).digest() != (
            self.fingerprint if fingerprint is None else fingerprint
        ):
            client.close()
            raise ValueError("certificate fingerprint mismatch")
        client.sendall(f"ILIDAR/1 {token}\n".encode())
        return client

    def authenticated(self):
        client = self.connect()
        self.assertEqual(client.recv(3), b"OK\n")
        return client

    def assert_rejected(self, client):
        try:
            self.assertEqual(client.recv(4096), b"")
        except (ConnectionResetError, ssl.SSLError):
            pass

    def test_authenticated_fragmented_upload(self):
        with self.authenticated() as client:
            data = packet("safe.jpg", payload=b"first", sequence=0, last=0)
            data += packet("safe.jpg", payload=b"second", sequence=1)
            for offset in range(0, len(data), 3):
                client.sendall(data[offset:offset + 3])
            self.assertIn(b"saved successfully", client.recv(1024))
        self.assertEqual((self.directory / "uploads" / "safe.jpg").read_bytes(), b"firstsecond")

    def test_rejects_bad_token_and_wrong_certificate(self):
        with self.connect(token="b" * 64) as client:
            self.assert_rejected(client)
        with self.assertRaises(ValueError):
            self.connect(fingerprint=b"\0" * 32)

    def test_rejects_plaintext(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as client:
            client.sendall(packet("plaintext.jpg"))
            self.assert_rejected(client)

    def test_rejects_paths_type_mismatch_and_large_headers(self):
        for data in (packet("../escape.jpg"), packet("mismatch.bin"),
                     packet("large.jpg", size=64 * 1024 + 1, payload=b""),
                     packet("invalid.jpg", last=2)):
            with self.subTest(data=data), self.authenticated() as client:
                client.sendall(data)
                self.assert_rejected(client)
        self.assertFalse((self.directory / "escape.jpg").exists())

    def test_existing_file_and_symlink_are_not_overwritten(self):
        uploads = self.directory / "uploads"
        target = self.directory / "target"
        target.write_bytes(b"keep")
        (uploads / "existing.jpg").write_bytes(b"original")
        os.symlink(target, uploads / "link.jpg")
        for name in ("existing.jpg", "link.jpg"):
            with self.subTest(name=name), self.authenticated() as client:
                client.sendall(packet(name))
                self.assert_rejected(client)
        self.assertEqual((uploads / "existing.jpg").read_bytes(), b"original")
        self.assertEqual(target.read_bytes(), b"keep")

    def test_rejects_duplicate_chunks_and_preserves_incomplete_file(self):
        with self.authenticated() as client:
            client.sendall(packet("duplicate.jpg", sequence=0, last=0) * 2)
            self.assert_rejected(client)
        self.assertFalse((self.directory / "uploads" / "duplicate.jpg").exists())

    def test_idle_connection_stays_open_but_partial_packet_times_out(self):
        code = """
import ssl, sys
sys.path.insert(0, sys.argv[1])
import ios_driver
ios_driver.SOCKET_TIMEOUT = 0.3
ios_driver.IDLE_TIMEOUT = 3
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
ios_driver.start_server('127.0.0.1', 0, context, b'a' * 64, sys.argv[4])
"""
        server = subprocess.Popen(
            [sys.executable, "-u", "-c", code, str(SERVER.parent), str(self.cert),
             str(self.key), str(self.directory / "timeout-uploads")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            line = server.stdout.readline()
            self.assertTrue(line.startswith("[*] Server listening on 127.0.0.1:"), line)
            self.port = int(line.rsplit(":", 1)[1])
            with self.authenticated() as client:
                time.sleep(0.7)
                client.sendall(packet("idle.jpg"))
                self.assertIn(b"saved successfully", client.recv(1024))
                client.sendall(b"\x08")
                self.assert_rejected(client)
            self.assertEqual((self.directory / "timeout-uploads" / "idle.jpg").read_bytes(), b"image")
        finally:
            if "port" in self.__dict__:
                del self.port
            server.terminate()
            server.wait(timeout=5)
            server.stdout.close()


if __name__ == "__main__":
    unittest.main()
