#!/usr/bin/env python3
"""A fake mote for bench tests: speaks the line protocol over mTLS.

    python3 cue9_stub_mote.py --ca ca.crt --cert mote.crt --key mote.key \
        --host 127.0.0.1 --port 7777

Prints every line it receives and answers ALIVE with PONG.
"""

from __future__ import annotations

import argparse
import socket
import ssl
import sys
import threading
import time


def main() -> int:
    ap = argparse.ArgumentParser(description="stub cue9 mote")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--ca", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--rssi", default="-55")
    ap.add_argument("--seconds", type=float, default=0.0)
    args = ap.parse_args()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(args.ca)
    ctx.load_cert_chain(args.cert, args.key)

    raw = socket.create_connection((args.host, args.port), timeout=5)
    tls = ctx.wrap_socket(raw)
    print("connected", flush=True)
    tls.sendall(f"READY {args.rssi}\n".encode())

    stop = threading.Event()

    def read_loop() -> None:
        try:
            reader = tls.makefile("rb")
            for raw_line in reader:
                line = raw_line.decode("utf-8", "replace").rstrip("\r\n")
                print("RX " + line, flush=True)
                if line == "ALIVE":
                    tls.sendall(b"PONG\n")
        except OSError:
            pass
        stop.set()

    threading.Thread(target=read_loop, daemon=True).start()
    if args.seconds:
        stop.wait(args.seconds)
    else:
        try:
            while not stop.is_set():
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
    tls.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
