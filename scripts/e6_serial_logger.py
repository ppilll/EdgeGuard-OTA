#!/usr/bin/env python3
"""
E6 serial logger.

Round-1 purpose:
- Open target UART.
- Continuously collect raw serial output.
- Prefix each line with host timestamp.
- Flush logs continuously.
- Allow keyword observation.
- Stop cleanly.

This module is intentionally simple and does not perform OTA orchestration.
"""

import argparse
import datetime as dt
import queue
import re
import sys
import threading
import time
from pathlib import Path
from typing import Iterable, Optional

import serial


class SerialLogger:
    def __init__(
        self,
        port: str,
        baudrate: int,
        log_path: str,
        timeout: float = 0.2,
        keywords: Optional[Iterable[str]] = None,
    ) -> None:
        self.port = port
        self.baudrate = baudrate
        self.log_path = Path(log_path)
        self.timeout = timeout
        self.keywords = list(keywords or [])
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._serial: Optional[serial.Serial] = None
        self._keyword_hits: "queue.Queue[dict]" = queue.Queue()
        self._lock = threading.Lock()
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

    def open(self) -> None:
        self._serial = serial.Serial(
            port=self.port,
            baudrate=self.baudrate,
            timeout=self.timeout,
            write_timeout=2,
        )

    def start(self) -> None:
        if self._serial is None:
            self.open()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="e6-serial-logger", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
        if self._serial and self._serial.is_open:
            self._serial.close()

    def write(self, text: str) -> None:
        if self._serial is None or not self._serial.is_open:
            raise RuntimeError("serial port is not open")
        self._serial.write(text.encode("utf-8", errors="replace"))
        self._serial.flush()

    def send_line(self, line: str) -> None:
        self.write(line.rstrip("\r\n") + "\n")

    def flush(self) -> None:
        if self._serial and self._serial.is_open:
            self._serial.flush()

    def keyword_hits(self) -> list:
        hits = []
        while True:
            try:
                hits.append(self._keyword_hits.get_nowait())
            except queue.Empty:
                break
        return hits

    def wait_for_keyword(self, pattern: str, timeout_sec: float) -> bool:
        deadline = time.time() + timeout_sec
        compiled = re.compile(pattern)
        while time.time() < deadline:
            for hit in self.keyword_hits():
                if compiled.search(hit["line"]):
                    return True
            time.sleep(0.1)
        return False

    def _timestamp(self) -> str:
        return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

    def _run(self) -> None:
        assert self._serial is not None
        buffer = b""

        with self.log_path.open("a", encoding="utf-8", buffering=1) as f:
            f.write(f"[{self._timestamp()}] === E6 serial logger started: {self.port} {self.baudrate} ===\n")
            f.flush()

            while not self._stop.is_set():
                try:
                    data = self._serial.read(256)
                except serial.SerialException as exc:
                    f.write(f"[{self._timestamp()}] SERIAL_EXCEPTION: {exc}\n")
                    f.flush()
                    time.sleep(0.5)
                    continue

                if not data:
                    continue

                buffer += data
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    line = raw_line.decode("utf-8", errors="replace").rstrip("\r")
                    stamped = f"[{self._timestamp()}] {line}"
                    with self._lock:
                        f.write(stamped + "\n")
                        f.flush()

                    for kw in self.keywords:
                        if kw in line:
                            self._keyword_hits.put(
                                {
                                    "timestamp": self._timestamp(),
                                    "keyword": kw,
                                    "line": line,
                                }
                            )

            if buffer:
                line = buffer.decode("utf-8", errors="replace")
                f.write(f"[{self._timestamp()}] {line}\n")
                f.flush()

            f.write(f"[{self._timestamp()}] === E6 serial logger stopped ===\n")
            f.flush()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="/dev/ttyUSB0")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=0.2)
    parser.add_argument(
        "--keywords",
        default="U-Boot,Starting kernel,Linux version,rauc,installing,BOOT_ORDER,health,watchdog,login:,#",
    )
    args = parser.parse_args()

    keywords = [x.strip() for x in args.keywords.split(",") if x.strip()]
    logger = SerialLogger(args.port, args.baudrate, args.log, args.timeout, keywords)

    try:
        logger.start()
        print(f"logging {args.port} at {args.baudrate} to {args.log}")
        print("press Ctrl-C to stop")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("stopping serial logger")
    finally:
        logger.stop()

    return 0


if __name__ == "__main__":
    sys.exit(main())
    