# Tau Wire Protocol

Binary wire protocol for client-server communication over TCP.

## Frame Layout

Every message — request or response — is a **10-byte fixed header** followed by an optional payload.

```
 0      1      2      3      4      5      6      7      8      9
+------+------+------+------+------+------+------+------+------+------+----------+
| 'T'  | 'A'  | 'U'  | ver  |  op  | flags|        payload_length       |  payload |
+------+------+------+------+------+------+------+------+------+------+----------+
|<---- 3 bytes magic ---->|  1b  |  1b  |  1b  |<-- 4 bytes big-endian u32 -->|  N bytes |
```

| Field            | Bytes | Type | Description                                      |
|------------------|-------|------|--------------------------------------------------|
| `magic`          | 0–2   | `[3]u8` | Always `"TAU"` (`0x54 0x41 0x55`).            |
| `version`        | 3     | `u8`    | Protocol version. Currently `1`.              |
| `opcode`         | 4     | `u8`    | Operation code (see table below).             |
| `flags`          | 5     | `u8`    | Reserved. Must be `0`.                        |
| `payload_length` | 6–9   | `u32`   | Big-endian. Max `4 194 304` (4 MiB).          |
| `payload`        | 10+   | `[N]u8` | Opcode-specific data. May be empty.           |

## Opcodes

### Connection Lifecycle

| Opcode       | Hex    | Direction | Payload |
|-------------|--------|-----------|---------|
| `connect`    | `0x01` | C → S     | 32-byte pre-shared certificate |
| `disconnect` | `0x02` | C → S     | (empty) |
| `ping`       | `0x03` | C → S     | (empty) |
| `pong`       | `0x04` | S → C     | (empty) |

### Series Management

| Opcode         | Hex    | Direction | Payload |
|---------------|--------|-----------|---------|
| `create_series` | `0x10` | C → S   | 32-byte label |
| `drop_series`   | `0x11` | C → S   | 32-byte label |

### Write Path

| Opcode   | Hex    | Direction | Payload |
|---------|--------|-----------|---------|
| `append` | `0x20` | C → S     | 32-byte label + 8-byte timestamp (i64, big-endian) + 8-byte value (f64 as u64, big-endian) = 48 bytes |

### Read Path

| Opcode        | Hex    | Direction | Payload |
|--------------|--------|-----------|---------|
| `query_point` | `0x30` | C → S    | 32-byte label + 8-byte timestamp (i64, big-endian) = 40 bytes |

### Lens Management

| Opcode         | Hex    | Direction | Payload |
|---------------|--------|-----------|---------|
| `create_lens`  | `0x40` | C → S    | 32-byte lens label + 32-byte source label + 32-byte transform name = 96 bytes |
| `drop_lens`    | `0x41` | C → S    | 32-byte label |
| `query_lens`   | `0x42` | C → S    | 32-byte label + 8-byte timestamp (i64, big-endian) = 40 bytes |
| `compose_lens` | `0x43` | C → S    | 32-byte new label + 32-byte lens1 label + 32-byte lens2 label = 96 bytes |
| `list_lenses`  | `0x44` | C → S    | (empty) |

### Response

| Opcode | Hex    | Direction | Payload |
|--------|--------|-----------|---------|
| `ok`   | `0xF0` | S → C     | Opcode-specific (see below) |
| `err`  | `0xFF` | S → C     | 1-byte status code |

## Payload Layouts

### CONNECT (0x01)

```
 0                              31
+-------------------------------+
|   32-byte pre-shared cert     |
+-------------------------------+
```

The client sends the 32-byte certificate configured in `src/config.zig`. The server compares it using constant-time equality. On success, the session is marked as authenticated and the server responds with `OK` (empty payload). On failure, the server responds with `ERR` status `0x06` (auth_failed) and closes the connection.

### DISCONNECT (0x02)

Empty payload. Server responds with `OK` and closes the connection.

### PING (0x03) / PONG (0x04)

Empty payload. Server responds with a `PONG` frame (opcode `0x04`, empty payload).

### CREATE_SERIES (0x10)

```
 0                              31
+-------------------------------+
|   32-byte series label        |
+-------------------------------+
```

Label is zero-padded on the right if shorter than 32 bytes. Server responds with `OK` or `ERR` (series_already_exists `0x08`).

### DROP_SERIES (0x11)

Same layout as CREATE_SERIES. Server responds with `OK` or `ERR` (series_not_found `0x07`).

### APPEND (0x20)

```
 0                              31   32          39   40          47
+-------------------------------+---------------+---------------+
|   32-byte series label        | i64 timestamp | f64 value     |
+-------------------------------+---------------+---------------+
```

- `timestamp`: 8 bytes, big-endian signed 64-bit integer (nanoseconds since epoch).
- `value`: 8 bytes, IEEE 754 f64 transmitted as big-endian u64 bitcast.

Timestamps must be strictly increasing per series. Server responds with `OK` or `ERR` (series_not_found `0x07`, out_of_order `0x0B`).

### QUERY_POINT (0x30)

```
 0                              31   32          39
+-------------------------------+---------------+
|   32-byte series label        | i64 timestamp |
+-------------------------------+---------------+
```

Server responds with `OK`:
- **Found**: 1 byte `0x01` + 8 bytes f64 value (big-endian u64 bitcast) = 9 bytes.
- **Not found**: 1 byte `0x00` = 1 byte.

### CREATE_LENS (0x40)

```
 0                              31   32                          63   64                          95
+-------------------------------+-------------------------------+-------------------------------+
|   32-byte lens label          |   32-byte source series label |   32-byte transform name      |
+-------------------------------+-------------------------------+-------------------------------+
```

Transform name is zero-padded. Available transforms: `identity`, `celsius_to_fahrenheit`, `fahrenheit_to_celsius`, `celsius_to_kelvin`, `kelvin_to_celsius`, `meters_to_feet`, `feet_to_meters`, `returns`, `log_return`.

### DROP_LENS (0x41)

Same layout as DROP_SERIES (32-byte label). Server responds with `OK` or `ERR` (lens_not_found `0x0C`).

### QUERY_LENS (0x42)

Same layout as QUERY_POINT (32-byte label + 8-byte timestamp). Response format is identical to QUERY_POINT.

### COMPOSE_LENS (0x43)

```
 0                              31   32                          63   64                          95
+-------------------------------+-------------------------------+-------------------------------+
|   32-byte new lens label      |   32-byte lens1 label         |   32-byte lens2 label         |
+-------------------------------+-------------------------------+-------------------------------+
```

Creates a new lens by composing two existing lenses. The composed lens uses lens1's source series and lens2's transform. Server responds with `OK` or `ERR` (lens_not_found `0x0C`, lens_already_exists `0x0D`).

### LIST_LENSES (0x44)

Empty payload. Server responds with `OK` whose payload is `N × 32` bytes — a concatenation of all lens labels (each 32 bytes, zero-padded). Empty payload if no lenses exist.

## Status Codes

| Code   | Name                  | Description                                      |
|--------|-----------------------|--------------------------------------------------|
| `0x00` | `success`             | Operation completed successfully.                |
| `0x01` | `bad_magic`           | Header magic bytes are not `"TAU"`.              |
| `0x02` | `bad_version`         | Unsupported protocol version.                    |
| `0x03` | `bad_opcode`          | Unknown or unsupported opcode.                   |
| `0x04` | `payload_too_large`   | Payload exceeds 4 MiB limit.                     |
| `0x05` | `not_authenticated`   | Command sent before successful CONNECT.          |
| `0x06` | `auth_failed`         | Certificate mismatch.                            |
| `0x07` | `series_not_found`    | Referenced series does not exist.                |
| `0x08` | `series_already_exists` | Series with this label already exists.          |
| `0x09` | `invalid_payload`     | Payload length or format is wrong for the opcode.|
| `0x0A` | `internal_error`      | Server-side error (catalog full, OOM, etc.).     |
| `0x0B` | `out_of_order`        | Append timestamp is not strictly increasing.     |
| `0x0C` | `lens_not_found`      | Referenced lens does not exist.                  |
| `0x0D` | `lens_already_exists` | Lens with this label already exists.             |

## Authentication Flow

1. Client opens a TCP connection to the server (default `127.0.0.1:7701`).
2. Client sends a `CONNECT` frame with a 32-byte pre-shared certificate as the payload.
3. Server compares the certificate against its configured value using **constant-time equality** (XOR-accumulate, no early exit) to prevent timing side-channels.
4. On match: server marks the session as authenticated and responds with `OK`.
5. On mismatch: server responds with `ERR` (auth_failed `0x06`) and closes the connection.
6. Any opcode other than `CONNECT` on an unauthenticated session receives `ERR` (not_authenticated `0x05`) and the connection is closed.
7. `DISCONNECT` clears the authenticated state and the server responds with `OK` before closing.

The certificate is configured at compile time in `src/config.zig` — there are no runtime config files or environment variables.

## Why

**Binary, not text.** A text protocol (like Redis RESP or HTTP) adds parsing overhead and ambiguity. Tau's fixed 10-byte header can be decoded with a single `read(10)` call and two integer reads — no scanning for delimiters, no allocation, no state machine. This matters for a time-series database where the write path must be as fast as possible.

**Big-endian for network order.** All multi-byte integers use big-endian (network byte order). This is the convention for wire protocols (TCP/IP, TLS, DNS) and avoids platform-specific byte-swapping bugs. The Zig standard library makes this explicit with `std.mem.readInt(..., .big)`.

**Bounded payload.** The 4 MiB payload limit (`payload_length_max = 4 * 1024 * 1024`) means the server can stack-allocate the receive buffer. No dynamic allocation on the read path. No amplification attacks via oversized payloads. The limit is enforced during header decode, before any payload bytes are read.

**One opcode per frame.** No batching, no pipelining, no multiplexing. Each frame is a self-contained request or response. This keeps the handler loop simple: read header, read payload, dispatch, respond. Throughput is achieved through the actor model — parallel writes across different series — not through protocol complexity.

**Pre-shared certificate, not TLS.** Tau targets single-machine or trusted-network deployments. A 32-byte pre-shared secret with constant-time comparison is simple, auditable, and has zero dependencies. TLS can be added as a transport layer if needed, without changing the wire protocol.
