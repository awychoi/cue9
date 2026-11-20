#!/usr/bin/env python3
"""Build cue9cfg.bin from the Pi setup summary plus Wi-Fi credentials.

    python3 make_cue9cfg.py --summary pi-summary.json \
        --ssid iot --psk secret --out cue9cfg.bin
"""

from __future__ import annotations

import argparse
import json


def main() -> int:
    ap = argparse.ArgumentParser(description="build the cue9 mote config partition")
    ap.add_argument("--summary", required=True, help="JSON printed by cue9_pi_setup.sh")
    ap.add_argument("--ssid", required=True)
    ap.add_argument("--psk", default="")
    ap.add_argument("--host", help="override the Pi host written into the config")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.summary, encoding="utf-8") as fh:
        summary = json.load(fh)

    config = {
        "wifi": {"ssid": args.ssid, "psk": args.psk},
        "host": args.host or summary["host"],
        "port": int(summary.get("port", 7777)),
        "ca": summary["ca"],
        "cert": summary["mote_cert"],
        "key": summary["mote_key"],
    }
    blob = b"CUE9CFG1\n" + json.dumps(config, separators=(",", ":")).encode("utf-8")
    blob = blob.ljust(16384, b"\x00")
    with open(args.out, "wb") as fh:
        fh.write(blob)
    print(f"{args.out}: {len(blob)} bytes, {config['host']}:{config['port']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
