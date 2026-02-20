import socket, struct

def main():
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

if __name__ == "__main__":
    main()
