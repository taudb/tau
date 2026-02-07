# Server

TCP database server for Tau. Speaks a custom binary protocol over the wire.

## Modules

| File | Purpose |
|---|---|
| `protocol.zig` | Wire format: 10-byte header, opcodes, status codes. |
| `auth.zig` | Pre-shared certificate authentication, session lifecycle. |
| `catalog.zig` | Thread-safe series registry with RwLock (readers concurrent, writers exclusive). |
| `handler.zig` | Per-connection request dispatch. |
| `listener.zig` | TCP accept loop, spawns a thread per connection. |
| `main.zig` | Entry point. |

## Running

Generate a 32-byte certificate (64 hex characters):

```sh
export TAU_CERTIFICATE=$(head -c 32 /dev/urandom | xxd -p -c 64)
```

Start the server:

```sh
zig build server
```

The server listens on `127.0.0.1:7701` by default.

## Connecting from Linux

Any TCP client that speaks the binary protocol can connect. A minimal session using `socat` or a custom client:

1. Open a TCP connection to `127.0.0.1:7701`.
2. Send a CONNECT frame (opcode `0x01`) with the 32-byte certificate as payload.
3. On success, the server responds with an OK frame (opcode `0xF0`).
4. Send commands (CREATE_SERIES, APPEND, QUERY_POINT, PING).
5. Send DISCONNECT (opcode `0x02`) to close gracefully.

### Wire format

```
Offset  Size  Field
0       3     Magic: "TAU"
3       1     Version: 0x01
4       1     Opcode
5       1     Flags (reserved, send 0x00)
6       4     Payload length (big-endian u32)
10      N     Payload
```

### Opcodes

| Code | Name | Payload (request) | Payload (response) |
|---|---|---|---|
| `0x01` | CONNECT | 32-byte certificate | — |
| `0x02` | DISCONNECT | — | — |
| `0x03` | PING | — | — |
| `0x04` | PONG | — | — |
| `0x10` | CREATE_SERIES | 32-byte label | — |
| `0x11` | DROP_SERIES | 32-byte label | — |
| `0x20` | APPEND | 32-byte label + 8-byte timestamp (BE i64) + 8-byte value (BE f64) | — |
| `0x30` | QUERY_POINT | 32-byte label + 8-byte timestamp (BE i64) | 1-byte found + 8-byte value (BE f64) if found |
| `0xF0` | OK | varies | — |
| `0xFF` | ERR | 1-byte status code | — |

### Example: raw connect with Python

```python
import socket, struct

cert = bytes.fromhex("your_64_hex_char_certificate_here")

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(("127.0.0.1", 7701))

# CONNECT
header = b"TAU" + bytes([1, 0x01, 0]) + struct.pack(">I", 32)
sock.sendall(header + cert)

# Read response header
resp = sock.recv(10)
opcode = resp[4]
print("OK" if opcode == 0xF0 else "ERR")

sock.close()
```

## Threading model

- One thread per connection (spawned on accept, detached).
- `Catalog` uses `RwLock`: queries take a shared lock, mutations take an exclusive lock.
- Multiple readers proceed concurrently; writes serialise.
