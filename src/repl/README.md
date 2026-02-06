# REPL

Interactive client for connecting to a running Tau server.

## Build and Run

```sh
zig build repl
```

This starts the REPL, which reads commands from stdin. Connect to a server before issuing data commands.

## Commands

| Command | Arguments | Description |
|---|---|---|
| `connect` | `[host] [port]` | Connect and authenticate. Defaults to `127.0.0.1 7701`. |
| `disconnect` | | Gracefully close the connection. |
| `ping` | | Send a PING, expect a PONG. |
| `create_series` | `<label>` | Create a new series. (`create` also works as a compatibility alias.) |
| `drop_series` | `<label>` | Drop an existing series. (`drop` also works as a compatibility alias.) |
| `append_point` | `<label> <timestamp> <value>` | Append a data point. Timestamp is an integer (nanoseconds), value is a float. (`append` alias supported.) |
| `query_point` | `<label> <timestamp>` | Point query a series at a timestamp. (`query` alias supported.) |
| `create_lens` | `<label> <source> <transform>` | Create a lens over a source series with a named transform. |
| `drop_lens` | `<label>` | Drop a lens. |
| `query_lens` | `<label> <timestamp>` | Query through a lens at a timestamp. |
| `compose_lens` | `<new> <lens1> <lens2>` | Compose two lenses into a new lens. |
| `list_lenses` | | List all lenses. |
| `transforms` | | List available transform names. |
| `help` | | Print command reference. |
| `quit` / `exit` | | Exit the REPL. |

### Available Transforms

`identity`, `celsius_to_fahrenheit`, `fahrenheit_to_celsius`, `celsius_to_kelvin`, `kelvin_to_celsius`, `meters_to_feet`, `feet_to_meters`, `returns`, `log_return`.

## Example Session

```
$ zig build repl
Commands:
  connect [host] [port]
  disconnect
  ping
  create_series <label>
  drop_series <label>
  append_point <label> <timestamp> <value>
  query_point <label> <timestamp>
  create_lens <label> <source> <transform>
  drop_lens <label>
  query_lens <label> <timestamp>
  compose_lens <new> <lens1> <lens2>
  list_lenses
  transforms
  help
  quit

Transforms:
  identity, celsius_to_fahrenheit, fahrenheit_to_celsius
  celsius_to_kelvin, kelvin_to_celsius
  meters_to_feet, feet_to_meters
  returns, log_return

tau> connect
connected to 127.0.0.1:7701
tau> ping
pong
tau> create_series temperature
ok
tau> append_point temperature 1000 22.5
ok
tau> append_point temperature 2000 23.1
ok
tau> query_point temperature 1000
value: 2.25e1
tau> query_point temperature 9999
not found
tau> create_lens temp_f temperature celsius_to_fahrenheit
ok
tau> query_lens temp_f 1000
value: 7.25e1
tau> list_lenses
  temp_f
tau> drop_lens temp_f
ok
tau> drop_series temperature
ok
tau> disconnect
disconnected
tau> quit
```

## Why

The REPL follows the TigerBeetle philosophy: **one tool for everything, Zig for scripts.** Rather than building a full CLI with subcommands, flags, and shell completion, Tau provides a single interactive client that speaks the wire protocol directly. This keeps the surface area small and the implementation auditable.

A standalone Python (or any language) client can be written in under 100 lines using raw sockets and `struct.pack` — the protocol is simple enough that the REPL is a convenience, not a necessity. See [EXAMPLES.md](../../EXAMPLES.md) for Python client examples.

The REPL itself is implemented in Zig, using only the standard library. No readline, no linenoise, no external dependencies. It imports only `tau` (for config) and `protocol` (for wire format constants).

## Tradeoffs

- **No tab completion.** Adding readline or linenoise would introduce an external dependency. The command set is small enough to memorise.
- **No history.** Same reason. Use shell history (`rlwrap zig-out/bin/repl`) if you want it.
- **Single-threaded blocking I/O.** The REPL sends a request and waits for the response before accepting the next command. This is intentional — interactive use does not need pipelining. Production clients should use the wire protocol directly with their own concurrency model.
- **No scripting mode.** Commands are read from stdin, so you can pipe a file into the REPL (`zig-out/bin/repl < commands.txt`), but there is no conditional logic or variables. For automation, write a Zig or Python script.
