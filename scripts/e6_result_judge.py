#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


PASS_CLASSES = {
    "upgrade_success",
    "rollback_success",
    "install_interrupted_but_recovered",
    "boot_recovered",
}


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def classify(meta, probe):
    if meta.get("infra_fail"):
        return {
            "result": "FAIL",
            "classification": "infra_fail",
            "reason": meta.get("infra_fail_reason", "Infrastructure failure"),
        }

    if not probe.get("reachable"):
        return {
            "result": "FAIL",
            "classification": "target_unreachable",
            "reason": "Target did not reach shell or serial probe failed",
        }

    if probe.get("rootfs_matches_slot") is not True:
        return {
            "result": "FAIL",
            "classification": "slot_mismatch",
            "reason": "rauc.slot does not match mounted rootfs",
        }

    if probe.get("data_mounted") is not True or probe.get("data_writable") is not True:
        return {
            "result": "FAIL",
            "classification": "data_mount_fail",
            "reason": "/data is not mounted or not writable",
        }

    if probe.get("rauc_status_ok") is not True:
        return {
            "result": "FAIL",
            "classification": "rauc_state_fail",
            "reason": "RAUC status is not readable",
        }

    if not probe.get("boot_order"):
        return {
            "result": "FAIL",
            "classification": "bootvars_invalid",
            "reason": "BOOT_ORDER is missing",
        }

    before_slot = meta.get("before_slot")
    before_version = meta.get("before_version")
    expected_new_version = meta.get("expected_new_version")
    after_slot = probe.get("slot")
    after_version = probe.get("version")

    if after_version == expected_new_version and after_slot != before_slot:
        return {
            "result": "PASS",
            "classification": "upgrade_success",
            "reason": "System booted the updated inactive slot and reached a consistent state",
        }

    if after_slot == before_slot and after_version == before_version:
        return {
            "result": "PASS",
            "classification": "rollback_success",
            "reason": "System recovered to the previous good slot after interrupted OTA",
        }

    if after_slot in ("A", "B") and probe.get("rootfs_matches_slot") is True:
        return {
            "result": "PASS",
            "classification": "install_interrupted_but_recovered",
            "reason": "System reached a bootable and explainable state after interrupted OTA",
        }

    return {
        "result": "FAIL",
        "classification": "unknown_fail",
        "reason": "System state is reachable but not explainable by current E6 rules",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    meta = load_json(args.meta)
    probe = load_json(args.probe)

    judgement = classify(meta, probe)

    result = {
        "round": meta.get("round"),
        "result": judgement["result"],
        "classification": judgement["classification"],
        "cut_delay_sec": meta.get("cut_delay_sec"),
        "power_off_duration_sec": meta.get("power_off_duration_sec"),
        "before_slot": meta.get("before_slot"),
        "after_slot": probe.get("slot"),
        "before_version": meta.get("before_version"),
        "after_version": probe.get("version"),
        "expected_new_version": meta.get("expected_new_version"),
        "before_boot_order": meta.get("before_boot_order"),
        "after_boot_order": probe.get("boot_order"),
        "after_boot_a_left": probe.get("boot_a_left"),
        "after_boot_b_left": probe.get("boot_b_left"),
        "requires_manual_reflash": False,
        "reason": judgement["reason"],
        "log_path": meta.get("log_path"),
    }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=False))

    return 0 if result["result"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())