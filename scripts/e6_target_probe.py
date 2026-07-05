#!/usr/bin/env python3
"""
E6 target probe over serial.

Round-1 purpose:
- Login to target shell over UART.
- Execute mandatory E6 probe commands.
- Parse minimum state.
- Save probe JSON.

This script intentionally does not use SSH by default.
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Pattern

import serial
import yaml


DEFAULT_COMMANDS = [
    "cat /etc/edgeguard_version",
    "cat /proc/cmdline",
    "edgeguard-current-slot",
    "findmnt /",
    "findmnt /data",
    "mount | grep /data",
    "rauc status",
    "rauc status --detailed",
    "fw_printenv BOOT_ORDER",
    "fw_printenv BOOT_A_LEFT",
    "fw_printenv BOOT_B_LEFT",
    "dmesg | tail -n 80",
]

FORBIDDEN_COMMANDS = [
    "cat /etc/edgeguard_slot",
]


ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PROMPT_RE = re.compile(r"^\s*[#\$]\s*$")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def _is_command_echo(line: str, command: str) -> bool:
    """
    Detect command echo lines.

    Serial shells may echo either:
    - command
    - # command
    - $ command
    """
    if not command:
        return False

    s = line.strip()
    cmd = command.strip()

    if s == cmd:
        return True

    if re.match(r"^[#\$]\s*" + re.escape(cmd) + r"\s*$", s):
        return True

    return False


def clean_shell_output(text: str, command: str = "") -> str:
    """
    Clean serial shell output.

    Removes:
    - ANSI escape sequences
    - CR characters
    - command echo line
    - __E6_DONE marker line
    - pure shell prompt lines such as # or $
    - empty surrounding lines

    Keeps real command output.
    """
    text = strip_ansi(text)
    text = text.replace("\r", "")

    cleaned = []
    for line in text.splitlines():
        s = line.strip()

        if not s:
            continue

        if _is_command_echo(s, command):
            continue

        if "__E6_DONE_" in s:
            continue

        if PROMPT_RE.match(s):
            continue

        cleaned.append(line.rstrip())

    return "\n".join(cleaned).strip()


def first_meaningful_line(text: str) -> str:
    text = clean_shell_output(text)
    for line in text.splitlines():
        s = line.strip()
        if s and not PROMPT_RE.match(s):
            return s
    return ""


def parse_edgeguard_current_slot(output: str) -> Optional[str]:
    output = clean_shell_output(output)

    m = re.search(r"^EDGEGUARD_SLOT=([AB])$", output, flags=re.MULTILINE)
    if m:
        return m.group(1)

    m = re.search(r"^EDGEGUARD_SLOT_RAW=([AB])$", output, flags=re.MULTILINE)
    if m:
        return m.group(1)

    # Fallback: if command outputs only A or B.
    m = re.search(r"^([AB])$", output, flags=re.MULTILINE)
    if m:
        return m.group(1)

    return None


def parse_version_output(output: str) -> str:
    return first_meaningful_line(output)


def parse_cmdline_output(output: str) -> str:
    return first_meaningful_line(output)


class SerialShell:
    def __init__(
        self,
        port: str,
        baudrate: int,
        timeout: float,
        prompt_regex: str,
        login_user: str = "root",
        login_password: str = "",
    ) -> None:
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.prompt_re = re.compile(prompt_regex.encode())
        self.login_user = login_user
        self.login_password = login_password
        self.ser: Optional[serial.Serial] = None

    def open(self) -> None:
        self.ser = serial.Serial(
            port=self.port,
            baudrate=self.baudrate,
            timeout=self.timeout,
            write_timeout=2,
        )

    def close(self) -> None:
        if self.ser and self.ser.is_open:
            self.ser.close()

    def write_line(self, line: str) -> None:
        assert self.ser is not None
        self.ser.write((line.rstrip("\r\n") + "\n").encode("utf-8", errors="replace"))
        self.ser.flush()

    def read_until_regex(self, regex: Pattern[bytes], timeout_sec: float) -> bytes:
        assert self.ser is not None
        deadline = time.time() + timeout_sec
        buf = b""

        while time.time() < deadline:
            chunk = self.ser.read(256)
            if chunk:
                buf += chunk
                if regex.search(buf):
                    return buf
            else:
                time.sleep(0.05)

        return buf

    def login(self, timeout_sec: float) -> bool:
        assert self.ser is not None

        # Wake shell/login prompt.
        for _ in range(3):
            self.write_line("")
            time.sleep(0.5)

        buf = self.read_until_regex(re.compile(rb"(login:|#|\$)"), timeout_sec=5)

        if b"login:" in buf:
            self.write_line(self.login_user)

            if self.login_password:
                buf = self.read_until_regex(re.compile(rb"(Password:|#|\$)"), timeout_sec=10)
                if b"Password:" in buf:
                    self.write_line(self.login_password)

        buf = self.read_until_regex(self.prompt_re, timeout_sec=timeout_sec)
        return bool(self.prompt_re.search(buf))

    def run_command(self, cmd: str, timeout_sec: float) -> Dict[str, object]:
        if cmd in FORBIDDEN_COMMANDS:
            return {
                "command": cmd,
                "return_hint": "forbidden",
                "output": "",
                "raw_output": "",
            }

        marker = f"__E6_DONE_{int(time.time() * 1000)}__"
        wrapped = f"{cmd}; echo {marker}:$?"

        self.write_line(wrapped)

        output = self.read_until_regex(
            re.compile(marker.encode("utf-8") + rb":\d+"),
            timeout_sec=timeout_sec,
        )
        text = output.decode("utf-8", errors="replace")

        rc = None
        m = re.search(re.escape(marker) + r":(\d+)", text)
        if m:
            rc = int(m.group(1))

        clean = clean_shell_output(text, command=wrapped)

        return {
            "command": cmd,
            "return_code": rc,
            "output": clean,
            "raw_output": text,
        }


def parse_rauc_slot(cmdline: str) -> Optional[str]:
    cmdline = clean_shell_output(cmdline)
    m = re.search(r"\brauc\.slot=([AB])\b", cmdline)
    return m.group(1) if m else None


def parse_rootfs(findmnt_root: str) -> Optional[str]:
    findmnt_root = clean_shell_output(findmnt_root)

    for dev in ["/dev/mmcblk0p2", "/dev/mmcblk0p3"]:
        if dev in findmnt_root:
            return dev

    m = re.search(r"(/dev/\S+)", findmnt_root)
    return m.group(1) if m else None


def parse_fw_var(output: str, name: str) -> Optional[str]:
    output = clean_shell_output(output)
    m = re.search(rf"^{re.escape(name)}=(.*)$", output, flags=re.MULTILINE)
    return m.group(1).strip() if m else None


def judge_rootfs_matches_slot(
    slot: Optional[str],
    rootfs: Optional[str],
    slot_a: str,
    slot_b: str,
) -> Optional[bool]:
    if not slot or not rootfs:
        return None

    if slot == "A":
        return rootfs == slot_a

    if slot == "B":
        return rootfs == slot_b

    return False


def build_probe(raw: Dict[str, Dict[str, object]], cfg: dict) -> dict:
    outputs = {cmd: str(info.get("output", "")) for cmd, info in raw.items()}

    version_text = parse_version_output(
        outputs.get("cat /etc/edgeguard_version", "")
    )

    cmdline = parse_cmdline_output(
        outputs.get("cat /proc/cmdline", "")
    )
    slot = parse_rauc_slot(cmdline)

    edgeguard_slot_text = parse_edgeguard_current_slot(
        outputs.get("edgeguard-current-slot", "")
    )

    rootfs = parse_rootfs(
        outputs.get("findmnt /", "")
    )

    data_output = outputs.get("findmnt /data", "")
    data_mounted = cfg["slots"]["data_device"] in data_output or "/data" in data_output

    boot_order = parse_fw_var(
        outputs.get("fw_printenv BOOT_ORDER", ""),
        "BOOT_ORDER",
    )
    boot_a_left = parse_fw_var(
        outputs.get("fw_printenv BOOT_A_LEFT", ""),
        "BOOT_A_LEFT",
    )
    boot_b_left = parse_fw_var(
        outputs.get("fw_printenv BOOT_B_LEFT", ""),
        "BOOT_B_LEFT",
    )

    rauc_status_ok = raw.get("rauc status", {}).get("return_code") == 0
    detailed_ok = raw.get("rauc status --detailed", {}).get("return_code") == 0

    dmesg_tail = outputs.get("dmesg | tail -n 80", "")
    watchdog_reset_observed = bool(
        re.search(r"watchdog|wdt|reset|reboot", dmesg_tail, flags=re.I)
    )

    rootfs_matches_slot = judge_rootfs_matches_slot(
        slot,
        rootfs,
        cfg["slots"]["slot_a_device"],
        cfg["slots"]["slot_b_device"],
    )

    slot_consistent = None
    if slot and edgeguard_slot_text:
        slot_consistent = slot == edgeguard_slot_text

    return {
        "reachable": True,
        "slot": slot,
        "slot_source": "rauc.slot" if slot else "unknown",
        "edgeguard_current_slot": edgeguard_slot_text,
        "slot_consistent": slot_consistent,
        "version": version_text,
        "cmdline": cmdline,
        "rootfs": rootfs,
        "rootfs_matches_slot": rootfs_matches_slot,
        "data_mounted": data_mounted,
        "data_writable": None,
        "rauc_status_ok": bool(rauc_status_ok and detailed_ok),
        "boot_order": boot_order,
        "boot_a_left": boot_a_left,
        "boot_b_left": boot_b_left,
        "health": "unknown",
        "watchdog_reset_observed": watchdog_reset_observed,
        "probe_method": "serial",
        "raw_outputs": raw,
    }


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    if cfg is None:
        raise ValueError(f"config file is empty or contains no YAML document: {path}")

    if not isinstance(cfg, dict):
        raise ValueError(f"config root must be a mapping/dict: {path}")

    return cfg


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="configs/e6_test_config.yaml")
    parser.add_argument("--output", required=True)
    parser.add_argument("--boot-wait", type=int, default=0)
    args = parser.parse_args()

    cfg = load_config(args.config)
    target = cfg["target"]

    if args.boot_wait > 0:
        print(f"waiting {args.boot_wait}s before serial login")
        time.sleep(args.boot_wait)

    shell = SerialShell(
        port=target["serial_port"],
        baudrate=int(target["baudrate"]),
        timeout=float(target.get("serial_timeout_sec", 0.2)),
        prompt_regex=target.get("prompt_regex", "#|\\$"),
        login_user=target.get("login_user", "root"),
        login_password=target.get("login_password", ""),
    )

    result = {}

    try:
        shell.open()

        ok = shell.login(
            timeout_sec=int(target.get("login_timeout_sec", 120))
        )

        if not ok:
            result = {
                "reachable": False,
                "probe_method": "serial",
                "reason": "login_timeout",
                "raw_outputs": {},
            }
        else:
            raw = {}

            for cmd in cfg.get("probe", {}).get("required_commands", DEFAULT_COMMANDS):
                if cmd in FORBIDDEN_COMMANDS:
                    continue

                raw[cmd] = shell.run_command(
                    cmd,
                    timeout_sec=int(target.get("command_timeout_sec", 20)),
                )

            data_cmd = cfg.get("probe", {}).get("data_write_test_command")
            if data_cmd:
                raw[data_cmd] = shell.run_command(
                    data_cmd,
                    timeout_sec=int(target.get("command_timeout_sec", 20)),
                )

            result = build_probe(raw, cfg)

            if data_cmd:
                result["data_writable"] = "DATA_WRITE_OK" in str(
                    raw[data_cmd].get("output", "")
                )

    except Exception as exc:
        result = {
            "reachable": False,
            "probe_method": "serial",
            "reason": f"exception: {exc}",
            "raw_outputs": {},
        }
    finally:
        shell.close()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(result, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(json.dumps(result, indent=2, ensure_ascii=False))

    return 0 if result.get("reachable") else 2


if __name__ == "__main__":
    sys.exit(main())