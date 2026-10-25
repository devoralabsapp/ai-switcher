"""Offline Unix WebSocket fixture; contains no real account or authentication data."""
import base64
import hashlib
import json
import os
import socket
import struct
import sys

path = sys.argv[1]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(1)
server.settimeout(10)
conn, _ = server.accept()
conn.settimeout(10)

def read(n):
    result = b""
    while len(result) < n:
        chunk = conn.recv(n - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result

def send(payload, opcode=1, final=True):
    length = len(payload)
    header = bytes([(128 if final else 0) | opcode])
    header += bytes([length]) if length < 126 else b"\x7e" + struct.pack("!H", length)
    conn.sendall(header + payload)

try:
    request = b""
    while not request.endswith(b"\r\n\r\n"):
        request += read(1)
    assert request.startswith(b"GET /rpc HTTP/1.1\r\n")
    headers = dict(line.split(":", 1) for line in request.decode().split("\r\n")[1:] if ":" in line)
    key = headers["Sec-WebSocket-Key"].strip()
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    while True:
        first, second = read(2)
        assert first & 128 and second & 128
        length = second & 127
        if length == 126:
            length = struct.unpack("!H", read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read(8))[0]
        assert length <= 8_388_608
        mask = read(4)
        payload = bytes(v ^ mask[i % 4] for i, v in enumerate(read(length)))
        if first & 15 == 10:
            assert payload == b"fixture-ping"
            continue
        item = json.loads(payload)
        if "id" not in item:
            continue
        method = item["method"]
        if method == "initialize":
            result = {"userAgent": "offline-fixture"}
        elif method == "account/read":
            result = {"account": {"type": "chatgpt", "email": "bridge@example.test", "planType": "plus"}}
        elif method == "account/rateLimits/read":
            result = {"accountId": "fixture-account", "rateLimits": {"primary": {"usedPercent": 23, "windowDurationMins": 300}}}
        else:
            raise AssertionError("Unexpected method")
        data = json.dumps({"id": item["id"], "result": result}).encode()
        send(data[:12], final=False)
        send(b"fixture-ping", opcode=9)
        send(data[12:], opcode=0)
except EOFError:
    pass
finally:
    conn.close()
    server.close()
    os.unlink(path)
