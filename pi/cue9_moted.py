#!/usr/bin/env python3
"""cue9-moted — the Pi end of the wireless mote link.

One TLS listener with mutual auth for the mote. One UNIX socket for
cue9-attach clients, which the DSH plugin starts over SSH.

This process is a pipe, not a brain. DSH decides the face; the mote renders it.
The only judgement made here is the heartbeat: ALIVE is sent only while a
client is attached. When the Mac goes away the heartbeat stops and the mote
falls back to its own hub scene, so a stale face never claims the agent is
still working.

stdlib only. Run it as a user service; see cue9_pi_setup.sh.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import ssl
import sys
import threading
import time

log = logging.getLogger("cue9-moted")

DEFAULTS = {
    "bind": "0.0.0.0",
    "port": 7777,
    "cert": "~/.config/cue9/tls/server.crt",
    "key": "~/.config/cue9/tls/server.key",
    "ca": "~/.config/cue9/tls/ca.crt",
    "sock": "~/.cache/cue9/mote.sock",
    "heartbeat_seconds": 2.0,
}
PATH_KEYS = ("cert", "key", "ca", "sock")


def default_config_path() -> str:
    return os.path.expanduser(os.environ.get("CUE9_CONFIG", "~/.config/cue9/moted.json"))


def load_config(path: str) -> dict:
    cfg = dict(DEFAULTS)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
        if not isinstance(loaded, dict):
            raise ValueError("config must be a JSON object")
        cfg.update(loaded)
    except FileNotFoundError:
        log.warning("no config at %s, using defaults", path)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"cannot read {path}: {exc}")
    for key in PATH_KEYS:
        cfg[key] = os.path.expanduser(str(cfg[key]))
    return cfg


def close_quietly(sock) -> None:
    if sock is None:
        return
    try:
        sock.close()
    except OSError:
        pass


class Service:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.started = time.time()
        self.stop = threading.Event()

        self.mote = None
        self.mote_connected = False
        self.mote_addr = None
        self.rssi = None
        self.error = None
        self.mote_lock = threading.RLock()

        self.clients = set()
        self.clients_lock = threading.Lock()

        self.cache = {"anim": None, "agents": None, "colors": {}, "backgrounds": {}}
        self.cache_lock = threading.Lock()

        self.last_client_alive = 0.0
        self.last_heartbeat = 0.0
        self._tcp = None
        self._unix = None

    # ---- outbound -----------------------------------------------------------

    def status(self) -> dict:
        return {
            "type": "status",
            "connected": self.mote_connected,
            "link": "wifi",
            "port": f"{self.cfg['bind']}:{self.cfg['port']}",
            "peer": self.mote_addr,
            "rssi": self.rssi,
            "clients": self.client_count(),
            "error": self.error,
            "uptime": round(time.time() - self.started, 1),
        }

    def client_count(self) -> int:
        with self.clients_lock:
            return len(self.clients)

    def _json_bytes(self, obj: dict) -> bytes:
        return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")

    def send_status(self) -> None:
        self.broadcast(self.status())

    def broadcast(self, obj: dict) -> None:
        data = self._json_bytes(obj)
        with self.clients_lock:
            targets = list(self.clients)
        for conn in targets:
            try:
                conn.sendall(data)
            except OSError:
                with self.clients_lock:
                    self.clients.discard(conn)
                close_quietly(conn)

    def send_mote(self, line: str, remember: bool = True) -> bool:
        if remember:
            self.remember(line)
        with self.mote_lock:
            tls = self.mote
            if tls is None or not self.mote_connected:
                return False
            try:
                tls.sendall((line + "\n").encode("utf-8"))
                return True
            except OSError as exc:
                self.error = str(exc)
        self._drop(tls, "send failed")
        return False

    # ---- cache --------------------------------------------------------------

    def remember(self, line: str) -> None:
        with self.cache_lock:
            if line.startswith("ANIM "):
                self.cache["anim"] = line
            elif line.startswith("AGENTS "):
                self.cache["agents"] = line
            elif line.startswith("COLOR "):
                parts = line.split()
                if len(parts) >= 2:
                    self.cache["colors"][parts[1]] = line
            elif line.startswith("BG "):
                parts = line.split()
                if len(parts) >= 2:
                    self.cache["backgrounds"][parts[1]] = line

    def replay(self) -> None:
        with self.cache_lock:
            lines = list(self.cache["colors"].values())
            lines += list(self.cache["backgrounds"].values())
            if self.cache["agents"]:
                lines.append(self.cache["agents"])
            if self.cache["anim"]:
                lines.append(self.cache["anim"])
        for line in lines:
            self.send_mote(line, remember=False)

    # ---- mote ---------------------------------------------------------------

    def _tls_context(self) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(self.cfg["cert"], self.cfg["key"])
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(self.cfg["ca"])
        ctx.set_ciphers(
            "ECDHE-ECDSA-AES128-GCM-SHA256:"
            "ECDHE-ECDSA-AES256-GCM-SHA384:"
            "ECDHE-RSA-AES128-GCM-SHA256"
        )
        return ctx

    @staticmethod
    def _tune(conn: socket.socket) -> None:
        try:
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            if hasattr(socket, "TCP_KEEPIDLE"):
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
            if hasattr(socket, "TCP_KEEPINTVL"):
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            if hasattr(socket, "TCP_KEEPCNT"):
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
        except OSError:
            pass

    def _adopt(self, tls: ssl.SSLSocket, peer: str) -> None:
        with self.mote_lock:
            old = self.mote
            self.mote = tls
            self.mote_connected = True
        self.mote_addr = peer
        self.rssi = None
        self.error = None
        if old is not None:
            close_quietly(old)
        log.info("mote connected from %s", peer)
        self.send_status()
        if self.client_count() > 0:
            self.replay()
        threading.Thread(target=self._mote_reader, args=(tls,), daemon=True).start()

    def _drop(self, tls, reason: str | None = None) -> None:
        with self.mote_lock:
            if self.mote is not tls:
                close_quietly(tls)
                return
            self.mote = None
            self.mote_connected = False
        if reason:
            self.error = reason
        close_quietly(tls)
        log.info("mote disconnected%s", f": {reason}" if reason else "")
        self.send_status()

    def _mote_reader(self, tls) -> None:
        buf = b""
        try:
            while not self.stop.is_set():
                chunk = tls.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    line = raw.decode("utf-8", "replace").strip()
                    if line:
                        self.handle_mote_line(line)
        except (OSError, ssl.SSLError) as exc:
            self._drop(tls, str(exc))
            return
        self._drop(tls)

    def handle_mote_line(self, line: str) -> None:
        if line.startswith("READY"):
            parts = line.split()
            if len(parts) > 1:
                try:
                    self.rssi = int(parts[1])
                except ValueError:
                    pass
            log.info("mote ready: %s", line)
            self.send_status()
            return
        self.broadcast({"type": "line", "line": line})

    def _mote_accept_loop(self) -> None:
        ctx = self._tls_context()
        lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        lsock.bind((self.cfg["bind"], int(self.cfg["port"])))
        lsock.listen(4)
        lsock.settimeout(1.0)
        self._tcp = lsock
        log.info("tls listening on %s:%s", self.cfg["bind"], self.cfg["port"])
        while not self.stop.is_set():
            try:
                conn, addr = lsock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._tune(conn)
            conn.settimeout(15.0)
            try:
                tls = ctx.wrap_socket(conn, server_side=True)
            except (ssl.SSLError, OSError) as exc:
                log.warning("tls handshake failed from %s: %s", addr[0], exc)
                close_quietly(conn)
                continue
            tls.settimeout(None)
            self._adopt(tls, addr[0])

    # ---- attach clients -----------------------------------------------------

    def handle_client_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        if line == "ALIVE":
            self.last_client_alive = time.monotonic()
        self.send_mote(line)

    def _client(self, conn: socket.socket) -> None:
        try:
            with self.clients_lock:
                self.clients.add(conn)
            conn.sendall(self._json_bytes(self.status()))
            reader = conn.makefile("rb")
            for raw in reader:
                text = raw.decode("utf-8", "replace").strip()
                if not text:
                    continue
                try:
                    obj = json.loads(text)
                except ValueError:
                    conn.sendall(self._json_bytes({"type": "error", "error": "bad json"}))
                    continue
                cmd = obj.get("cmd")
                if isinstance(cmd, str):
                    self.handle_client_line(cmd)
        except OSError:
            pass
        finally:
            with self.clients_lock:
                self.clients.discard(conn)
            close_quietly(conn)

    def _client_accept_loop(self) -> None:
        path = self.cfg["sock"]
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        lsock.bind(path)
        os.chmod(path, 0o600)
        lsock.listen(8)
        lsock.settimeout(1.0)
        self._unix = lsock
        log.info("attach socket at %s", path)
        while not self.stop.is_set():
            try:
                conn, _ = lsock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()

    # ---- heartbeat ----------------------------------------------------------

    def _heartbeat_loop(self) -> None:
        while not self.stop.is_set():
            self.stop.wait(0.5)
            if self.stop.is_set():
                break
            if self.client_count() == 0 or not self.mote_connected:
                self.last_client_alive = 0.0
                self.last_heartbeat = 0.0
                continue
            now = time.monotonic()
            # A Mac that fell asleep leaves its SSH socket open; only the
            # client's own ALIVE proves DSH is still there.
            if now - self.last_client_alive > 5.0:
                continue
            if now - self.last_heartbeat >= float(self.cfg["heartbeat_seconds"]):
                self.last_heartbeat = now
                self.send_mote("ALIVE")

    # ---- lifecycle ----------------------------------------------------------

    def run(self) -> int:
        log.info(
            "starting: bind=%s port=%s cert=%s ca=%s",
            self.cfg["bind"], self.cfg["port"], self.cfg["cert"], self.cfg["ca"],
        )
        threading.Thread(target=self._mote_accept_loop, daemon=True).start()
        threading.Thread(target=self._client_accept_loop, daemon=True).start()
        threading.Thread(target=self._heartbeat_loop, daemon=True).start()

        def _stop(_signum, _frame):
            self.stop.set()

        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)

        while not self.stop.is_set():
            self.stop.wait(1.0)

        log.info("stopping")
        for sock in (self._tcp, self._unix):
            close_quietly(sock)
        with self.mote_lock:
            close_quietly(self.mote)
            self.mote = None
            self.mote_connected = False
        try:
            os.unlink(self.cfg["sock"])
        except OSError:
            pass
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="cue9 mote service")
    ap.add_argument("--config", default=default_config_path())
    ap.add_argument("--bind")
    ap.add_argument("--port", type=int)
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--ca")
    ap.add_argument("--sock")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    cfg = load_config(args.config)
    for name in ("bind", "port", "cert", "key", "ca", "sock"):
        value = getattr(args, name)
        if value is not None:
            cfg[name] = os.path.expanduser(value) if name in PATH_KEYS else value
    if not os.path.exists(cfg["cert"]) or not os.path.exists(cfg["key"]):
        log.error("missing TLS material: %s / %s", cfg["cert"], cfg["key"])
        return 2
    return Service(cfg).run()


if __name__ == "__main__":
    sys.exit(main())
