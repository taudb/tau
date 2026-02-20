# Server

TCP database server for Tau. Speaks a custom binary protocol over the wire.

## Configuration

All configuration is in `src/config.zig`:

```zig
pub const server = struct {
    pub const port: u16 = 7701;
    pub const address: [4]u8 = .{ 127, 0, 0, 1 };
    pub const certificate: [32]u8 = .{ ... };  // 32-byte pre-shared key
    pub const max_connections: u32 = 1024;
    pub const connection_timeout_ms: u32 = 30_000;
    pub const max_payload_bytes: u32 = 1024 * 1024;
    pub const catalog_capacity: u32 = 10_000;
    pub const actor_pool_size: u32 = 0;  // 0 = CPU core count
    pub const mailbox_capacity: u32 = 1024;
};
```

**Important**: Change the certificate before production use. The default certificate is for development only.

## Modules

| File | Purpose |
|---|---|
| `protocol.zig` | Wire format: 10-byte header, opcodes, status codes. |
| `auth.zig` | Pre-shared certificate authentication, session lifecycle. |
| `actor.zig` | Actor model: Message, Mailbox, SeriesActor, ActorPool, ResponseSlot. |
| `catalog.zig` | Series registry: routes operations to actor mailboxes. |
| `handler.zig` | Per-connection request dispatch. |
| `listener.zig` | TCP accept loop, spawns a thread per connection. |
| `main.zig` | Entry point. |

## Running

```sh
zig build server
```

Listens on the configured address and port (default: `127.0.0.1:7701`).

## Wire format

```
Offset  Size  Field
0       3     Magic: "TAU"
3       1     Version: 0x01
4       1     Opcode
5       1     Flags (reserved, send 0x00)
6       4     Payload length (big-endian u32)
10      N     Payload
```

## Opcodes

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

## Example: raw connect with Python

```python
import socket, struct

# Get certificate from config.zig (convert hex bytes to bytes)
cert = bytes([
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
])

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

- **One thread per connection** (spawned on accept, detached).
- **Actor-based concurrency**: Each series is an independent actor with its own mailbox.
- **Worker thread pool**: Fixed-size pool (default: CPU core count) processes messages from actor mailboxes.
- **Zero cross-series contention**: Operations on different series proceed in full parallel.
- **Lock-free data path**: Series data is actor-private; only the routing table (create/drop) uses a small RwLock.
- **Bounded mailboxes**: Each actor has a bounded ring buffer mailbox (default: 1024 messages) for back-pressure.
