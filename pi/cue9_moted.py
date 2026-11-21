#!/usr/bin/env python3
"""cue9-moted — the Pi end of the wireless mote link.

One TLS listener with mutual auth for the mote. One UNIX socket for
cue9-attach clients, which the DSH plugin starts over SSH.

This process is a pipe, not a brain. DSH decides the face; the mote renders it.
The only judgement made here is the heartbeat: ALIVE is sent only while a
client is attached. When the Mac goes away the heartbeat stops and the mote
falls back to its own hub scene, so a stale face never claims the agent is
still working.

The Pi also feeds the mote's ambient pages: TIME from its own NTP-synced clock
and WX from Open-Meteo. Those lines are pushed while the mote is connected,
with or without a Mac attached. They are deliberately not cached, not replayed
and not counted as client liveness.

stdlib only. Run it as a user service; see cue9_pi_setup.sh.
"""

from __future__ import annotations

import argparse
import datetime
import json
import logging
import os
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request

try:
    from zoneinfo import ZoneInfo
except ImportError:   # very old Python; the Pi keeps its own zone
    ZoneInfo = None

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

AMBIENT_DEFAULTS = {
    "enabled": True,
    "city": "",            # empty: derive from the Pi's timezone
    "lat": None,           # number, or geocoded from city
    "lon": None,
    "units": "auto",       # auto | celsius | fahrenheit
    "clock": 12,           # 12 or 24
    "timezone": "",        # IANA name; empty = the Pi's own zone
    "time_seconds": 15.0,  # TIME cadence while the mote is connected
    "weather_seconds": 900.0,
}

WEATHER_URL = "https://api.open-meteo.com/v1/forecast"
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"


def city_from_timezone(tz: str) -> str:
    """America/New_York -> New York; a bare UTC-like zone has no city."""
    name = (tz or "").rsplit("/", 1)[-1].replace("_", " ").strip()
    return "" if name.lower() in {"utc", "gmt", "etc", "unknown"} else name


def system_timezone() -> str:
    """The IANA zone, which time.tzname does not give (it gives EST/EDT)."""
    try:
        with open("/etc/timezone", "r", encoding="utf-8") as fh:
            name = fh.read().strip()
        if name:
            return name
    except OSError:
        pass
    return os.environ.get("TZ", "")


def condition_for(code: int) -> str:
    """WMO weather code -> one of the four icons the mote draws."""
    if code == 0:
        return "sunny"
    if code in (71, 73, 75, 77, 85, 86):
        return "snow"
    if 51 <= code <= 67 or 80 <= code <= 82 or 95 <= code <= 99:
        return "rain"
    return "partly"   # 1-3 cloud, 45/48 fog, and anything unrecognised


class Ambient:
    """Pushes TIME and WX to the mote. Runs whether or not a Mac is attached."""

    def __init__(self, service: "Service"):
        cfg = dict(AMBIENT_DEFAULTS)
        loaded = service.cfg.get("ambient")
        if isinstance(loaded, dict):
            cfg.update(loaded)
        self.service = service
        self.cfg = cfg
        self.enabled = bool(cfg.get("enabled", True))
        self.city = str(cfg.get("city") or "").strip()
        self.lat = cfg.get("lat")
        self.lon = cfg.get("lon")
        self.tz_name = str(cfg.get("timezone") or "").strip()
        self.lock = threading.RLock()
        self.units = str(cfg.get("units") or "auto").lower()
        try:
            self.clock = 24 if int(cfg.get("clock", 12)) == 24 else 12
        except (TypeError, ValueError):
            self.clock = 12
        self.force_time = False
        self.force_weather = False
        self.wx_line = None
        self._resolved = False

    # ---- scheduling ---------------------------------------------------------

    def poke(self) -> None:
        """Send now: the mote just (re)connected."""
        self.force_time = True
        self.force_weather = True

    def start(self) -> None:
        if not self.enabled:
            log.info("ambient off")
            return
        threading.Thread(target=self._time_loop, name="ambient-time", daemon=True).start()
        threading.Thread(target=self._weather_loop, name="ambient-wx", daemon=True).start()

    def _units(self) -> str:
        if self.units in ("celsius", "fahrenheit"):
            return self.units
        return "fahrenheit" if system_timezone().startswith("America/") else "celsius"

    def _offset_minutes(self) -> int:
        zone = None
        if self.tz_name and ZoneInfo is not None:
            try:
                zone = ZoneInfo(self.tz_name)
            except Exception:
                zone = None
        when = datetime.datetime.now(zone) if zone is not None else datetime.datetime.now().astimezone()
        offset = when.utcoffset()
        return int(offset.total_seconds() // 60) if offset is not None else 0

    def _time_line(self) -> str:
        now = time.time()
        return f"TIME {int(now)} {self._offset_minutes()} {self.clock}"

    def _time_loop(self) -> None:
        interval = max(5.0, float(self.cfg.get("time_seconds") or 15.0))
        last = -1e9
        while not self.service.stop.wait(0.5):
            if not self.service.mote_connected:
                continue
            now = time.monotonic()
            if not self.force_time and now - last < interval:
                continue
            self.force_time = False
            if self.service.send_mote(self._time_line(), remember=False):
                last = now

    def _weather_loop(self) -> None:
        interval = max(120.0, float(self.cfg.get("weather_seconds") or 900.0))
        last = -1e9
        while not self.service.stop.wait(1.0):
            if not self.service.mote_connected:
                continue
            now = time.monotonic()
            if not self.force_weather and now - last < interval:
                continue
            self.force_weather = False
            line = self._fetch_line()
            if line is not None and self.service.send_mote(line, remember=False):
                self.wx_line = line
                last = now
            elif line is None:
                last = now   # a failed fetch waits a full interval; no hammering

    # ---- config from the app ------------------------------------------------

    def to_dict(self) -> dict:
        with self.lock:
            return {
                "enabled": self.enabled,
                "timezone": self.tz_name,
                "city": self.city,
                "lat": self.lat,
                "lon": self.lon,
                "units": self.units,
                "clock": self.clock,
                "time_seconds": self.cfg.get("time_seconds", 15.0),
                "weather_seconds": self.cfg.get("weather_seconds", 900.0),
            }

    def snapshot(self) -> dict:
        data = self.to_dict()
        data["pi_zone"] = system_timezone()
        data["units_effective"] = self._units()
        return data

    def apply(self, payload: dict) -> None:
        """Settings from the cue9 app. Persisted in moted.json, applied live."""
        if not isinstance(payload, dict):
            raise ValueError("ambient payload must be an object")
        with self.lock:
            if "timezone" in payload:
                name = str(payload.get("timezone") or "").strip()
                if name:
                    if ZoneInfo is None:
                        raise ValueError("this Python has no zoneinfo")
                    try:
                        ZoneInfo(name)
                    except Exception:
                        raise ValueError(f"unknown timezone {name!r}")
                self.tz_name = name
            if "city" in payload:
                self.city = str(payload.get("city") or "").strip()[:40]
            if "lat" in payload or "lon" in payload:
                lat, lon = payload.get("lat"), payload.get("lon")
                if lat is None or lon is None:
                    self.lat = self.lon = None
                else:
                    lat, lon = float(lat), float(lon)
                    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                        raise ValueError("coordinates out of range")
                    self.lat, self.lon = lat, lon
            if "units" in payload:
                unit = str(payload.get("units") or "").lower()
                if unit in ("f", "fahrenheit"):
                    self.units = "fahrenheit"
                elif unit in ("c", "celsius"):
                    self.units = "celsius"
                elif unit == "auto":
                    self.units = "auto"
                else:
                    raise ValueError("units must be fahrenheit or celsius")
            if "clock" in payload:
                clock = int(payload["clock"])
                if clock not in (12, 24):
                    raise ValueError("clock must be 12 or 24")
                self.clock = clock
        self.force_time = True
        self.force_weather = True

    # ---- weather ------------------------------------------------------------

    def _location(self) -> tuple[float, float, str] | None:
        if self.lat is not None and self.lon is not None:
            try:
                return float(self.lat), float(self.lon), self.city
            except (TypeError, ValueError):
                pass
        city = self.city or city_from_timezone(system_timezone())
        if not city:
            return None
        query = urllib.parse.urlencode({"name": city, "count": 1, "language": "en", "format": "json"})
        with urllib.request.urlopen(f"{GEOCODE_URL}?{query}", timeout=8) as resp:
            data = json.load(resp)
        results = data.get("results") or []
        if not results:
            log.warning("weather: no place found for %r", city)
            return None
        hit = results[0]
        with self.lock:
            self.lat = hit.get("latitude")
            self.lon = hit.get("longitude")
            self.city = hit.get("name") or city
            return float(self.lat), float(self.lon), self.city

    def _fetch_line(self) -> str | None:
        try:
            place = self._location()
            if place is None:
                return None
            lat, lon, label = place
            query = urllib.parse.urlencode({
                "latitude": lat,
                "longitude": lon,
                "current": "temperature_2m,apparent_temperature,weather_code",
                "daily": "temperature_2m_max,temperature_2m_min,weather_code",
                "forecast_days": 1,
                "timezone": "auto",
                "temperature_unit": self._units(),
            })
            with urllib.request.urlopen(f"{WEATHER_URL}?{query}", timeout=8) as resp:
                data = json.load(resp)
            cur = data["current"]
            daily = data["daily"]
            temp = int(round(float(cur["temperature_2m"])))
            feels = int(round(float(cur["apparent_temperature"])))
            hi = int(round(float(daily["temperature_2m_max"][0])))
            lo = int(round(float(daily["temperature_2m_min"][0])))
            code = int(cur.get("weather_code", 0))
            city = "".join(c for c in label.upper() if 32 <= ord(c) < 127)[:18].strip()
            unit = "F" if self._units() == "fahrenheit" else "C"
            return f"WX {condition_for(code)}|{temp}|{hi}|{lo}|{feels}|{unit}|{city}"
        except (OSError, ValueError, KeyError, TypeError) as exc:
            log.warning("weather fetch failed: %s", exc)
            return None



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
    def __init__(self, cfg: dict, cfg_path: str = ""):
        self.cfg = cfg
        self.cfg_path = cfg_path
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
        self.ambient = Ambient(self)

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
            "ambient": self.ambient.snapshot(),
        }

    def client_count(self) -> int:
        with self.clients_lock:
            return len(self.clients)

    def _json_bytes(self, obj: dict) -> bytes:
        return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")

    def send_status(self) -> None:
        self.broadcast(self.status())

    def save_config(self) -> None:
        """Write the ambient block back to moted.json so it survives restarts."""
        if not self.cfg_path:
            return
        data = dict(self.cfg)
        data["ambient"] = self.ambient.to_dict()
        tmp = self.cfg_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, self.cfg_path)

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
        self.ambient.poke()
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

    def handle_client_line(self, line: str, conn=None) -> None:
        line = line.strip()
        if not line:
            return
        if line.startswith("AMBIENT "):
            reply = {"type": "ambient", "ok": False}
            try:
                self.ambient.apply(json.loads(line[8:]))
                self.save_config()
                reply["ok"] = True
                reply["ambient"] = self.ambient.snapshot()
            except (ValueError, TypeError, OSError) as exc:
                reply["error"] = str(exc)
            if conn is not None:
                try:
                    conn.sendall(self._json_bytes(reply))
                except OSError:
                    pass
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
                    self.handle_client_line(cmd, conn)
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
        self.ambient.start()

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
    return Service(cfg, os.path.expanduser(args.config)).run()


if __name__ == "__main__":
    sys.exit(main())
