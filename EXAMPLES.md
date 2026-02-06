# Examples

Practical use cases for Tau. Each example shows REPL commands, equivalent Python client code, and expected output. The same socket protocol can be implemented in any language that can read and write raw TCP bytes.

All examples assume the server is running (`zig build server`) on the default address `127.0.0.1:7701` with the default certificate.

---

## Temperature Monitoring with Unit Conversion

Record Celsius readings from a sensor and create a lens to view them in Fahrenheit.

### REPL

```
tau> connect
connected to 127.0.0.1:7701
tau> create_series temperature_c
ok
tau> append_point temperature_c 1000 22.5
ok
tau> append_point temperature_c 2000 23.1
ok
tau> append_point temperature_c 3000 21.8
ok
tau> query_point temperature_c 2000
value: 2.31e1
tau> create_lens temp_f temperature_c celsius_to_fahrenheit
ok
tau> query_lens temp_f 1000
value: 7.25e1
tau> query_lens temp_f 2000
value: 7.358e1
tau> query_lens temp_f 3000
value: 7.124e1
tau> disconnect
disconnected
```

### Python

```python
import socket
import struct

HOST = "127.0.0.1"
PORT = 7701
MAGIC = b"TAU"
VERSION = 1
LABEL_LEN = 32

# Pre-shared certificate from src/config.zig (default dev cert).
CERTIFICATE = bytes(range(0x00, 0x20))

def make_label(name):
    return name.encode("utf-8").ljust(LABEL_LEN, b"\x00")[:LABEL_LEN]

def send(sock, opcode, payload=b""):
    header = (
        MAGIC
        + bytes([VERSION, opcode, 0])
        + struct.pack(">I", len(payload))
    )
    sock.sendall(header + payload)

def recv_response(sock):
    header = sock.recv(10)
    assert header[:3] == MAGIC
    opcode = header[4]
    payload_len = struct.unpack(">I", header[6:10])[0]
    payload = sock.recv(payload_len) if payload_len > 0 else b""
    return opcode, payload

def connect(sock):
    send(sock, 0x01, CERTIFICATE)
    opcode, _ = recv_response(sock)
    assert opcode == 0xF0, "CONNECT failed"

def create_series(sock, name):
    send(sock, 0x10, make_label(name))
    opcode, _ = recv_response(sock)
    assert opcode == 0xF0

def append(sock, name, timestamp, value):
    payload = make_label(name)
    payload += struct.pack(">q", timestamp)
    payload += struct.pack(">d", value)
    send(sock, 0x20, payload)
    opcode, _ = recv_response(sock)
    assert opcode == 0xF0

def query_point(sock, name, timestamp):
    payload = make_label(name) + struct.pack(">q", timestamp)
    send(sock, 0x30, payload)
    opcode, resp = recv_response(sock)
    assert opcode == 0xF0
    if resp[0] == 1:
        return struct.unpack(">d", resp[1:9])[0]
    return None

def create_lens(sock, name, source, transform):
    payload = make_label(name) + make_label(source)
    payload += transform.encode("utf-8").ljust(32, b"\x00")[:32]
    send(sock, 0x40, payload)
    opcode, _ = recv_response(sock)
    assert opcode == 0xF0

def query_lens(sock, name, timestamp):
    payload = make_label(name) + struct.pack(">q", timestamp)
    send(sock, 0x42, payload)
    opcode, resp = recv_response(sock)
    assert opcode == 0xF0
    if resp[0] == 1:
        return struct.unpack(">d", resp[1:9])[0]
    return None

# --- Main ---
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect((HOST, PORT))

connect(sock)

create_series(sock, "temperature_c")

append(sock, "temperature_c", 1000, 22.5)
append(sock, "temperature_c", 2000, 23.1)
append(sock, "temperature_c", 3000, 21.8)

val = query_point(sock, "temperature_c", 2000)
print(f"Celsius at t=2000: {val}")  # 23.1

create_lens(sock, "temp_f", "temperature_c", "celsius_to_fahrenheit")

for t in [1000, 2000, 3000]:
    f = query_lens(sock, "temp_f", t)
    print(f"Fahrenheit at t={t}: {f:.1f}")

send(sock, 0x02)  # DISCONNECT
sock.close()
```

### Expected Output

```
Celsius at t=2000: 23.1
Fahrenheit at t=1000: 72.5
Fahrenheit at t=2000: 73.6
Fahrenheit at t=3000: 71.2
```

---

## Financial Time Series with Log Returns

Track stock prices at nanosecond timestamps. Create lenses for simple returns and log returns, then compose them.

### REPL

```
tau> connect
connected to 127.0.0.1:7701
tau> create_series stock_price
ok
tau> append_point stock_price 1000000000 100.00
ok
tau> append_point stock_price 2000000000 102.50
ok
tau> append_point stock_price 3000000000 101.75
ok
tau> append_point stock_price 4000000000 105.20
ok
tau> query_point stock_price 2000000000
value: 1.025e2
tau> create_lens simple_ret stock_price returns
ok
tau> create_lens log_ret stock_price log_return
ok
tau> query_lens simple_ret 2000000000
value: 1.025e2
tau> query_lens log_ret 3000000000
value: 1.0175e2
tau> list_lenses
  simple_ret
  log_ret
tau> compose_lens composed simple_ret log_ret
ok
tau> list_lenses
  simple_ret
  log_ret
  composed
tau> disconnect
disconnected
```

### Python

```python
import socket
import struct
import math

HOST, PORT = "127.0.0.1", 7701
MAGIC = b"TAU"
CERT = bytes(range(0x00, 0x20))

def make_label(name):
    return name.encode().ljust(32, b"\x00")[:32]

def send(sock, opcode, payload=b""):
    header = MAGIC + bytes([1, opcode, 0]) + struct.pack(">I", len(payload))
    sock.sendall(header + payload)

def recv(sock):
    hdr = sock.recv(10)
    op = hdr[4]
    plen = struct.unpack(">I", hdr[6:10])[0]
    data = sock.recv(plen) if plen > 0 else b""
    return op, data

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect((HOST, PORT))

# Connect
send(sock, 0x01, CERT)
recv(sock)

# Create series
send(sock, 0x10, make_label("stock_price"))
recv(sock)

# Append prices at nanosecond timestamps
prices = [
    (1_000_000_000, 100.00),
    (2_000_000_000, 102.50),
    (3_000_000_000, 101.75),
    (4_000_000_000, 105.20),
]
for ts, val in prices:
    payload = make_label("stock_price") + struct.pack(">q", ts) + struct.pack(">d", val)
    send(sock, 0x20, payload)
    recv(sock)

# Create lenses
for name, transform in [("simple_ret", "returns"), ("log_ret", "log_return")]:
    payload = make_label(name) + make_label("stock_price")
    payload += transform.encode().ljust(32, b"\x00")[:32]
    send(sock, 0x40, payload)
    recv(sock)

# Query through lenses
for lens_name in ["simple_ret", "log_ret"]:
    payload = make_label(lens_name) + struct.pack(">q", 2_000_000_000)
    send(sock, 0x42, payload)
    op, data = recv(sock)
    if data[0] == 1:
        val = struct.unpack(">d", data[1:9])[0]
        print(f"{lens_name} at t=2e9: {val}")

# Compose lenses
payload = make_label("composed") + make_label("simple_ret") + make_label("log_ret")
send(sock, 0x43, payload)
recv(sock)

# List all lenses
send(sock, 0x44, b"")
op, data = recv(sock)
count = len(data) // 32
print(f"Lenses ({count}):")
for i in range(count):
    label = data[i*32:(i+1)*32].rstrip(b"\x00").decode()
    print(f"  {label}")

send(sock, 0x02)
sock.close()
```

### Expected Output

```
simple_ret at t=2e9: 102.5
log_ret at t=2e9: 102.5
Lenses (3):
  simple_ret
  log_ret
  composed
```

---

## Multi-Sensor IoT Pipeline

Ingest data from multiple sensors in parallel. Each series is an independent actor with its own mailbox, so writes to different series do not contend.

### REPL

```
tau> connect
connected to 127.0.0.1:7701
tau> create_series sensor_temp
ok
tau> create_series sensor_pressure
ok
tau> create_series sensor_voltage
ok
tau> append_point sensor_temp 1000 22.5
ok
tau> append_point sensor_pressure 1000 101325.0
ok
tau> append_point sensor_voltage 1000 3.3
ok
tau> append_point sensor_temp 2000 23.1
ok
tau> append_point sensor_pressure 2000 101300.0
ok
tau> append_point sensor_voltage 2000 3.28
ok
tau> query_point sensor_temp 1000
value: 2.25e1
tau> query_point sensor_pressure 1000
value: 1.01325e5
tau> query_point sensor_voltage 2000
value: 3.28e0
tau> disconnect
disconnected
```

### Python

```python
import socket
import struct

HOST, PORT = "127.0.0.1", 7701
MAGIC = b"TAU"
CERT = bytes(range(0x00, 0x20))

def make_label(name):
    return name.encode().ljust(32, b"\x00")[:32]

def send(sock, opcode, payload=b""):
    header = MAGIC + bytes([1, opcode, 0]) + struct.pack(">I", len(payload))
    sock.sendall(header + payload)

def recv(sock):
    hdr = sock.recv(10)
    plen = struct.unpack(">I", hdr[6:10])[0]
    return hdr[4], sock.recv(plen) if plen > 0 else b""

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect((HOST, PORT))

send(sock, 0x01, CERT)
recv(sock)

sensors = {
    "sensor_temp":     [(1000, 22.5),  (2000, 23.1)],
    "sensor_pressure": [(1000, 101325.0), (2000, 101300.0)],
    "sensor_voltage":  [(1000, 3.3),   (2000, 3.28)],
}

# Create all series
for name in sensors:
    send(sock, 0x10, make_label(name))
    recv(sock)

# Append data (in practice, different connections write in parallel
# — each series is an actor with its own mailbox)
for name, readings in sensors.items():
    for ts, val in readings:
        payload = make_label(name) + struct.pack(">qd", ts, val)
        send(sock, 0x20, payload)
        recv(sock)

# Query across series
for name in sensors:
    payload = make_label(name) + struct.pack(">q", 1000)
    send(sock, 0x30, payload)
    op, data = recv(sock)
    if data[0] == 1:
        val = struct.unpack(">d", data[1:9])[0]
        print(f"{name} at t=1000: {val}")

send(sock, 0x02)
sock.close()
```

### Expected Output

```
sensor_temp at t=1000: 22.5
sensor_pressure at t=1000: 101325.0
sensor_voltage at t=1000: 3.3
```

Each series is backed by its own `SeriesActor`. The actor pool (sized to CPU core count by default, configurable via `config.server.actor_pool_size`) processes mailbox messages in parallel. Writes to `sensor_temp` never block writes to `sensor_pressure`.

---

## Voltage Monitoring with Meters-to-Feet Conversion

Record altitude measurements in meters and view them in feet through a lens.

### REPL

```
tau> connect
connected to 127.0.0.1:7701
tau> create_series altitude_m
ok
tau> append_point altitude_m 100 1500.0
ok
tau> append_point altitude_m 200 1520.5
ok
tau> append_point altitude_m 300 1485.3
ok
tau> create_lens altitude_ft altitude_m meters_to_feet
ok
tau> query_point altitude_m 100
value: 1.5e3
tau> query_lens altitude_ft 100
value: 4.92126e3
tau> query_lens altitude_ft 200
value: 4.98917402e3
tau> query_lens altitude_ft 300
value: 4.87270485e3
tau> list_lenses
  altitude_ft
tau> drop_lens altitude_ft
ok
tau> list_lenses
no lenses
tau> disconnect
disconnected
```

### Python

```python
import socket
import struct

HOST, PORT = "127.0.0.1", 7701
MAGIC = b"TAU"
CERT = bytes(range(0x00, 0x20))

def make_label(name):
    return name.encode().ljust(32, b"\x00")[:32]

def send(sock, opcode, payload=b""):
    header = MAGIC + bytes([1, opcode, 0]) + struct.pack(">I", len(payload))
    sock.sendall(header + payload)

def recv(sock):
    hdr = sock.recv(10)
    plen = struct.unpack(">I", hdr[6:10])[0]
    return hdr[4], sock.recv(plen) if plen > 0 else b""

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect((HOST, PORT))

send(sock, 0x01, CERT)
recv(sock)

# Create series
send(sock, 0x10, make_label("altitude_m"))
recv(sock)

# Append altitude readings in meters
for ts, val in [(100, 1500.0), (200, 1520.5), (300, 1485.3)]:
    payload = make_label("altitude_m") + struct.pack(">qd", ts, val)
    send(sock, 0x20, payload)
    recv(sock)

# Create meters-to-feet lens
payload = make_label("altitude_ft") + make_label("altitude_m")
payload += "meters_to_feet".encode().ljust(32, b"\x00")
send(sock, 0x40, payload)
recv(sock)

# Query through lens
for ts in [100, 200, 300]:
    payload = make_label("altitude_ft") + struct.pack(">q", ts)
    send(sock, 0x42, payload)
    op, data = recv(sock)
    if data[0] == 1:
        val = struct.unpack(">d", data[1:9])[0]
        print(f"Altitude at t={ts}: {val:.1f} ft")

# Drop the lens
send(sock, 0x41, make_label("altitude_ft"))
recv(sock)

send(sock, 0x02)
sock.close()
```

### Expected Output

```
Altitude at t=100: 4921.3 ft
Altitude at t=200: 4988.5 ft
Altitude at t=300: 4872.7 ft
```

The conversion factor is `1 meter = 3.28084 feet`, applied lazily by the lens on each query — no data is copied or materialised.
