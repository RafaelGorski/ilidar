"""Receive authenticated iLiDAR uploads over TLS."""

import argparse
import hmac
import os
import re
import socket
import ssl
import struct
import threading
import time

DATA_TYPE_EXTENSION = {1: ".jpg", 2: ".bin", 3: ".csv"}
FILENAME_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,200}\.(?:jpg|bin|csv)\Z")
TOKEN_PATTERN = re.compile(rb"[0-9a-f]{64}\Z")
MAX_PACKET_SIZE = 64 * 1024
MAX_FILE_SIZE = 16 * 1024 * 1024
MAX_BUFFERED_BYTES = 32 * 1024 * 1024
MAX_CHUNKS = 16384
MAX_ACTIVE_FILES = 32
MAX_CLIENTS = 8
SOCKET_TIMEOUT = 15
IDLE_TIMEOUT = 300


class ProtocolError(Exception):
    pass


class FileReceiver:
    def __init__(self, data_type):
        self.data_type = data_type
        self.chunks = {}
        self.total_size = 0
        self.last_sequence = None

    def add_chunk(self, sequence, payload, is_last):
        if sequence >= MAX_CHUNKS or sequence in self.chunks:
            raise ProtocolError("invalid or duplicate sequence number")
        if self.last_sequence is not None and (is_last or sequence > self.last_sequence):
            raise ProtocolError("invalid final sequence")
        if is_last and any(seq > sequence for seq in self.chunks):
            raise ProtocolError("final sequence precedes an existing chunk")
        if self.total_size + len(payload) > MAX_FILE_SIZE:
            raise ProtocolError("file too large")
        self.chunks[sequence] = payload
        self.total_size += len(payload)
        if is_last:
            self.last_sequence = sequence

    def is_complete(self):
        return self.last_sequence is not None and len(self.chunks) == self.last_sequence + 1


class ClientHandler(threading.Thread):
    def __init__(self, client_socket, client_address, tls_context, token, save_directory, slots):
        super().__init__(daemon=True)
        self.client_socket = client_socket
        self.client_address = client_address
        self.tls_context = tls_context
        self.token = token
        self.save_directory = save_directory
        self.slots = slots
        self.buffer = b""
        self.files = {}
        self.buffered_bytes = 0

    def run(self):
        try:
            self.client_socket.settimeout(SOCKET_TIMEOUT)
            self.client_socket = self.tls_context.wrap_socket(self.client_socket, server_side=True)
            self.authenticate()
            print(f"[+] Authenticated connection from {self.client_address}")
            packet_deadline = None
            while True:
                timeout = IDLE_TIMEOUT
                if packet_deadline is not None:
                    timeout = packet_deadline - time.monotonic()
                    if timeout <= 0:
                        raise ProtocolError("packet timed out")
                self.client_socket.settimeout(timeout)
                data = self.client_socket.recv(4096)
                if not data:
                    break
                if not self.buffer:
                    packet_deadline = time.monotonic() + SOCKET_TIMEOUT
                self.buffer += data
                packet_completed = self.process_buffer()
                if not self.buffer:
                    packet_deadline = None
                elif packet_completed:
                    packet_deadline = time.monotonic() + SOCKET_TIMEOUT
        except (OSError, ssl.SSLError, ProtocolError, UnicodeDecodeError) as error:
            print(f"[!] Client {self.client_address}: {error}")
        finally:
            self.client_socket.close()
            self.slots.release()

    def authenticate(self):
        # A fixed-length authentication record prevents unbounded reads.
        record = bytearray()
        deadline = time.monotonic() + SOCKET_TIMEOUT
        while len(record) < 74:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProtocolError("authentication timed out")
            self.client_socket.settimeout(remaining)
            data = self.client_socket.recv(74 - len(record))
            if not data:
                raise ProtocolError("incomplete authentication")
            record.extend(data)
        if not hmac.compare_digest(bytes(record), b"ILIDAR/1 " + self.token + b"\n"):
            raise ProtocolError("authentication failed")
        self.client_socket.sendall(b"OK\n")

    def process_buffer(self):
        packet_completed = False
        while self.buffer:
            filename_length = self.buffer[0]
            if not filename_length:
                raise ProtocolError("empty filename")
            header_size = 11 + filename_length
            if len(self.buffer) < header_size:
                return packet_completed
            filename = self.buffer[1:1 + filename_length].decode("utf-8")
            data_type, size, sequence, is_last = struct.unpack(
                ">BIIB", self.buffer[1 + filename_length:header_size]
            )
            if (not FILENAME_PATTERN.fullmatch(filename)
                    or DATA_TYPE_EXTENSION.get(data_type) != os.path.splitext(filename)[1]):
                raise ProtocolError("invalid filename or data type")
            if size == 0 or size > MAX_PACKET_SIZE or sequence >= MAX_CHUNKS or is_last not in (0, 1):
                raise ProtocolError("invalid packet header")
            if len(self.buffer) < header_size + size:
                return packet_completed
            payload = self.buffer[header_size:header_size + size]
            self.buffer = self.buffer[header_size + size:]
            self.handle_packet(filename, data_type, sequence, bool(is_last), payload)
            packet_completed = True
        return packet_completed

    def handle_packet(self, filename, data_type, sequence, is_last, payload):
        receiver = self.files.get(filename)
        if receiver is None:
            if len(self.files) >= MAX_ACTIVE_FILES:
                raise ProtocolError("too many incomplete files")
            receiver = self.files[filename] = FileReceiver(data_type)
        if receiver.data_type != data_type or self.buffered_bytes + len(payload) > MAX_BUFFERED_BYTES:
            raise ProtocolError("invalid type or buffered data limit exceeded")
        receiver.add_chunk(sequence, payload, is_last)
        self.buffered_bytes += len(payload)
        print(f"[>] Received packet: {filename!r}, sequence {sequence}, {len(payload)} bytes")
        if receiver.is_complete():
            path = os.path.join(self.save_directory, filename)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(path, flags, 0o600)
            try:
                with os.fdopen(fd, "wb") as output:
                    for chunk in range(receiver.last_sequence + 1):
                        output.write(receiver.chunks[chunk])
            except BaseException:
                os.unlink(path)
                raise
            self.buffered_bytes -= receiver.total_size
            del self.files[filename]
            self.client_socket.sendall(f"File '{filename}' received and saved successfully.".encode())
            print(f"[+] File saved: {filename!r}")


def start_server(host, port, tls_context, token, save_directory):
    os.makedirs(save_directory, mode=0o700, exist_ok=True)
    slots = threading.BoundedSemaphore(MAX_CLIENTS)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(MAX_CLIENTS)
        print(f"[*] Server listening on {host}:{server.getsockname()[1]}", flush=True)
        while True:
            client, address = server.accept()
            if not slots.acquire(blocking=False):
                client.close()
                continue
            try:
                ClientHandler(client, address, tls_context, token, save_directory, slots).start()
            except Exception:
                client.close()
                slots.release()
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default: loopback)")
    parser.add_argument("--port", type=int, default=5678)
    parser.add_argument("--cert", required=True, help="PEM server certificate")
    parser.add_argument("--key", required=True, help="PEM private key")
    parser.add_argument("--token-file", required=True, help="file containing a 64-character lowercase hex token")
    parser.add_argument("--uploads", default="uploads", help="upload directory")
    args = parser.parse_args()
    with open(args.token_file, "rb") as token_file:
        token = token_file.read(66).strip()
    if not TOKEN_PATTERN.fullmatch(token):
        parser.error("token file must contain exactly 64 lowercase hexadecimal characters")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    try:
        start_server(args.host, args.port, context, token, args.uploads)
    except KeyboardInterrupt:
        print("\n[!] Server shutting down.")


if __name__ == "__main__":
    main()
