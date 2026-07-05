#!/usr/bin/env python3
"""
E6 power control.

Round-1 only implements manual mode.

Manual mode behavior:
- Ask operator to cut target low-voltage DC input.
- Wait for Enter confirmation.
- Record power_off timestamp.
- Wait configured off_duration_sec.
- Ask operator to restore target power.
- Wait for Enter confirmation.
- Record power_on timestamp.
- Emit JSON event record.

Do not control AC mains.
"""

import argparse
import datetime as dt
import json
import sys
import time
from pathlib import Path

import yaml


def now_iso() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def manual_power_cycle(off_duration_sec: int) -> dict:
    print("")
    print("=== E6 MANUAL POWER CUT ===")
    print("Safety boundary: cut only the target board low-voltage DC input.")
    print("Do NOT switch AC mains.")
    print("")
    input("1) Cut target power now, then press Enter to confirm power is OFF... ")
    power_off_time = now_iso()
    print(f"power_off_time={power_off_time}")

    print(f"Waiting configured off duration: {off_duration_sec}s")
    time.sleep(off_duration_sec)

    input("2) Restore target power now, then press Enter to confirm power is ON... ")
    power_on_time = now_iso()
    print(f"power_on_time={power_on_time}")

    return {
        "mode": "manual",
        "result": "ok",
        "classification_on_error": "infra_fail",
        "power_off_time": power_off_time,
        "power_on_time": power_on_time,
        "off_duration_sec": off_duration_sec,
        "safety_note": "low-voltage DC side only; AC mains switching is forbidden",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="configs/e6_test_config.yaml")
    parser.add_argument("--output", default="reports/logs/level1_manual_power_event.json")
    parser.add_argument("--off-duration", type=int, default=None)
    args = parser.parse_args()

    cfg = load_config(args.config)
    power = cfg.get("power", {})
    mode = power.get("mode", "manual")

    if mode != "manual":
        print(f"Round-1 template only supports manual mode, got mode={mode}", file=sys.stderr)
        return 2

    off_duration_sec = args.off_duration
    if off_duration_sec is None:
        off_duration_sec = int(power.get("off_duration_sec", 5))

    try:
        event = manual_power_cycle(off_duration_sec)
    except Exception as exc:
        event = {
            "mode": "manual",
            "result": "error",
            "classification": "infra_fail",
            "reason": str(exc),
            "timestamp": now_iso(),
        }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(event, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(event, indent=2, ensure_ascii=False))

    return 0 if event.get("result") == "ok" else 2


if __name__ == "__main__":
    sys.exit(main())
    