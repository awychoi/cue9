#!/usr/bin/env bash
# cue9 Pi setup: install the mote service, mint TLS material, start the unit.
#
# Run as the target user (not root). Progress goes to stderr; the last line on
# stdout is a JSON summary for the cue9 app, including the mote client cert and
# key that must be flashed into the device.
set -euo pipefail

PORT=7777
BIND=0.0.0.0
FORCE=0
RUN_KEY_FILE=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: cue9_pi_setup.sh [--port N] [--bind ADDR] [--force] [--run-key-file PATH]
  --port          TLS port for the mote (default 7777)
  --bind          listen address (default 0.0.0.0)
  --force         regenerate CA and certificates
  --run-key-file  install a public key restricted to cue9-attach
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --bind) BIND="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --run-key-file) RUN_KEY_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

PY="$(command -v python3)" || die "python3 is required"
command -v openssl >/dev/null || die "openssl is required"
command -v systemctl >/dev/null || die "systemd is required"

DATA="$HOME/.local/share/cue9"
CONF="$HOME/.config/cue9"
TLS="$CONF/tls"
CACHE="$HOME/.cache/cue9"
SOCK="$CACHE/mote.sock"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/cue9-moted.service"

mkdir -p "$DATA" "$TLS" "$CACHE" "$UNIT_DIR"
chmod 700 "$CONF" "$TLS" "$CACHE"

say "installing code into $DATA"
install -m 755 "$HERE/cue9_moted.py" "$DATA/cue9_moted.py"
install -m 755 "$HERE/cue9_attach.py" "$DATA/cue9_attach.py"

HOST_IP="${CUE9_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
[[ -n "$HOST_IP" ]] || HOST_IP="$BIND"
[[ "$HOST_IP" == "0.0.0.0" ]] && HOST_IP="127.0.0.1"

if [[ $FORCE -eq 1 || ! -s "$TLS/ca.crt" || ! -s "$TLS/server.crt" || ! -s "$TLS/mote.crt" ]]; then
  say "generating TLS material (EC P-256)"
  rm -f "$TLS"/*.crt "$TLS"/*.key "$TLS"/*.csr "$TLS"/*.srl
  openssl ecparam -name prime256v1 -genkey -noout -out "$TLS/ca.key"
  openssl req -x509 -new -key "$TLS/ca.key" -out "$TLS/ca.crt" -days 3650 -sha256 \
    -subj "/CN=cue9-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  openssl ecparam -name prime256v1 -genkey -noout -out "$TLS/server.key"
  openssl req -new -key "$TLS/server.key" -out "$TLS/server.csr" \
    -subj "/CN=cue9-moted" >/dev/null 2>&1
  openssl x509 -req -in "$TLS/server.csr" -CA "$TLS/ca.crt" -CAkey "$TLS/ca.key" \
    -CAcreateserial -out "$TLS/server.crt" -days 3650 -sha256 \
    -extfile <(printf 'subjectAltName=IP:%s\n' "$HOST_IP") >/dev/null 2>&1
  openssl ecparam -name prime256v1 -genkey -noout -out "$TLS/mote.key"
  openssl req -new -key "$TLS/mote.key" -out "$TLS/mote.csr" \
    -subj "/CN=cue9-mote" >/dev/null 2>&1
  openssl x509 -req -in "$TLS/mote.csr" -CA "$TLS/ca.crt" -CAkey "$TLS/ca.key" \
    -CAserial "$TLS/ca.srl" -out "$TLS/mote.crt" -days 3650 -sha256 >/dev/null 2>&1
  rm -f "$TLS"/*.csr
fi
chmod 600 "$TLS"/*.key
chmod 644 "$TLS"/*.crt

"$PY" - "$CONF/moted.json" "$BIND" "$PORT" "$TLS" "$SOCK" <<'PY'
import json, sys
path, bind, port, tls, sock = sys.argv[1:6]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "bind": bind,
        "port": int(port),
        "cert": tls + "/server.crt",
        "key": tls + "/server.key",
        "ca": tls + "/ca.crt",
        "sock": sock,
        "heartbeat_seconds": 2.0,
    }, fh, indent=2)
    fh.write("\n")
PY

cat > "$UNIT" <<EOF
[Unit]
Description=cue9 mote service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PY $DATA/cue9_moted.py --config $CONF/moted.json
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    say "enabled lingering for $USER"
  elif sudo -n loginctl enable-linger "$USER" >/dev/null 2>&1; then
    say "enabled lingering for $USER (sudo)"
  else
    say "warning: could not enable linger; the service will stop when you log out"
    say "         run: sudo loginctl enable-linger $USER"
  fi
fi

say "starting cue9-moted"
systemctl --user daemon-reload
systemctl --user enable cue9-moted >/dev/null 2>&1 || true
systemctl --user restart cue9-moted

for _ in $(seq 1 20); do
  [[ -S "$SOCK" ]] && break
  sleep 0.25
done

if [[ -n "$RUN_KEY_FILE" && -s "$RUN_KEY_FILE" ]]; then
  say "restricting the cue9 run key"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  "$PY" - "$HOME/.ssh/authorized_keys" "$RUN_KEY_FILE" "$PY" "$DATA/cue9_attach.py" <<'PY'
import os, sys
path, key_path, python, attach = sys.argv[1:5]
with open(key_path, encoding="utf-8") as fh:
    key = fh.read().strip().splitlines()[0]
body = key.split()[1] if len(key.split()) > 1 else key
entry = (
    f'command="{python} {attach}",no-pty,no-agent-forwarding,'
    f'no-port-forwarding,no-X11-forwarding {key}'
)
with open(path, encoding="utf-8") as fh:
    lines = [line for line in fh.read().splitlines() if body not in line]
lines.append(entry)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines).rstrip("\n") + "\n")
os.chmod(path, 0o600)
PY
fi

STATUS="$("$PY" "$DATA/cue9_attach.py" --sock "$SOCK" --status 2>/dev/null || true)"
[[ -n "$STATUS" ]] || STATUS='{"connected":false,"error":"service did not answer"}'

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  say "warning: ufw is active; allow the mote subnet to reach tcp/$PORT"
fi

say "done: https://$HOST_IP:$PORT (mutual TLS)"

"$PY" - "$HOST_IP" "$PORT" "$TLS" "$STATUS" <<'PY'
import json, os, sys
host, port, tls, status = sys.argv[1:5]
def read(name):
    with open(tls + "/" + name, encoding="utf-8") as fh:
        return fh.read()
try:
    parsed = json.loads(status)
except ValueError:
    parsed = None
user = os.environ.get("USER") or "pi"
print(json.dumps({
    "ok": True,
    "user": user,
    "bridge": f"{user}@{host}",
    "host": host,
    "port": int(port),
    "service": "cue9-moted",
    "status": parsed,
    "ca": read("ca.crt"),
    "mote_cert": read("mote.crt"),
    "mote_key": read("mote.key"),
}))
PY
