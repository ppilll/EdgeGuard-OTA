#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-$HOME/桌面/project/EdgeGuard_OTA}"
BR="${BR:-$PROJECT/external/buildroot}"
OUT="${OUT:-$PROJECT/output/edgeguard-imx6ull}"
DEF="$PROJECT/configs/buildroot_defconfig"
LOG_DIR="$PROJECT/reports/logs"
BR2_DL_DIR="${BR2_DL_DIR:-$HOME/buildroot-dl}"
export BR2_DL_DIR
mkdir -p "$BR2_DL_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/build_rootfs_${TS}.log"

mkdir -p "$LOG_DIR"

echo "PROJECT=$PROJECT"
echo "BR=$BR"
echo "OUT=$OUT"
echo "DEF=$DEF"
echo "LOG=$LOG"

if [ ! -f "$BR/Makefile" ]; then
  echo "ERROR: Buildroot Makefile not found: $BR/Makefile"
  exit 1
fi

if [ ! -f "$DEF" ]; then
  echo "ERROR: defconfig not found: $DEF"
  exit 1
fi

make -C "$BR" O="$OUT" defconfig BR2_DEFCONFIG="$DEF" 2>&1 | tee "$LOG"
make -C "$BR" O="$OUT" -j"$(nproc)" 2>&1 | tee -a "$LOG"

echo
echo "Build finished."
echo "Images:"
find "$OUT/images" -maxdepth 1 -type f -printf "%p\n" | sort || true

echo
echo "Version file:"
cat "$OUT/target/etc/edgeguard_version"

echo
echo "Log saved to: $LOG"