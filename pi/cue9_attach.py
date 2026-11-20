#!/usr/bin/env python3
"""cue9-attach — the DSH plugin's handle on cue9-moted, over SSH.

stdin: plain command lines. stdout: JSON lines, the same shape usb_bridge.py
emits, so the plugin's parser is unchanged.

    ssh -T pi@mote 'python3 ~/.local/share/cue9/cue9_attach.py'

The SSH key is locked down with a forced command, so this is all it can run.
`--status` is a one-shot probe for the cue9 app.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading


def default_sock() -> str:
    return os.path.expanduser(os.environ.get("CUE9_SOCK", "~/.cache/cue9/mote.sock"))


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def read_line(sock: socket.socket) -> bytes | None:
    buf = b""
    while b"\n" not in buf:
        try:
            chunk = sock.recv(4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    if not buf:
        return None
    return buf.split(b"\n", 1)[0] + b"\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="attach to cue9-moted")
    ap.add_argument("--sock", default=default_sock())
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(args.timeout)
    try:
        sock.connect(os.path.expanduser(args.sock))
    except OSError as exc:
        emit({"type": "status", "connected": False, "link": "wifi",
              "error": f"cannot reach cue9-moted: {exc}"})
        return 1
    sock.settimeout(None)

    if args.status:
        line = read_line(sock)
        sock.close()
        if line is None:
            emit({"type": "status", "connected": False, "link": "wifi",
                  "error": "cue9-moted closed the connection"})
            return 1
        sys.stdout.write(line.decode("utf-8", "replace"))
        sys.stdout.flush()
        return 0

    def pump_out() -> None:
        try:
            reader = sock.makefile("rb")
            for raw in reader:
                sys.stdout.buffer.write(raw)
                sys.stdout.buffer.flush()
        except OSError:
            pass
        finally:
            emit({"type": "status", "connected": False, "link": "wifi",
                  "error": "cue9-moted closed the connection"})
            os._exit(0)

    threading.Thread(target=pump_out, daemon=True).start()

    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            sock.sendall((json.dumps({"cmd": line}) + "\n").encode("utf-8"))
    except (OSError, BrokenPipeError):
        pass
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()
    # The reader thread is still parked on stdout/socket; skip interpreter
    # finalization rather than racing it at shutdown.
    os._exit(0)


if __name__ == "__main__":
    sys.exit(main())
