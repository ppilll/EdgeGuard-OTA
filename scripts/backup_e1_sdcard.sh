#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  sudo $0 <sd-device> [backup-dir]

Example:
  sudo $0 /dev/sdX
  sudo $0 /dev/mmcblk1 backups/e1_sdcard

Notes:
  - <sd-device> must be a whole disk, not a partition.
  - This script only backs up; it does not write to the SD card.
  - Compatible with older Ubuntu lsblk versions that do not support MOUNTPOINTS.
USAGE
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

DEV="$1"
OUTDIR="${2:-backups/e1_sdcard}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: please run with sudo/root."
  exit 1
fi

if [ ! -b "$DEV" ]; then
  echo "ERROR: $DEV is not a block device."
  exit 1
fi

TYPE="$(lsblk -dn -o TYPE "$DEV" 2>/dev/null || true)"
if [ "$TYPE" != "disk" ]; then
  echo "ERROR: $DEV is not a whole disk. Do not pass a partition like /dev/sdX1."
  echo
  echo "Current device info:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV" || true
  exit 1
fi

ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
ROOT_PKNAME=""
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
  ROOT_PKNAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
fi

if [ -n "$ROOT_PKNAME" ] && [ "/dev/$ROOT_PKNAME" = "$DEV" ]; then
  echo "ERROR: $DEV appears to contain the host root filesystem. Refusing."
  exit 1
fi

# Check whether the disk itself or any child partition is mounted.
MOUNTED_FOUND=0

if findmnt -rn -S "$DEV" >/dev/null 2>&1; then
  MOUNTED_FOUND=1
fi

while IFS= read -r CHILD; do
  if [ -n "$CHILD" ] && findmnt -rn -S "$CHILD" >/dev/null 2>&1; then
    MOUNTED_FOUND=1
  fi
done <<CHILDREN
$(lsblk -nrpo NAME "$DEV" 2>/dev/null | tail -n +2)
CHILDREN

if [ "$MOUNTED_FOUND" -ne 0 ]; then
  echo "ERROR: one or more partitions on $DEV are mounted."
  echo "Please unmount them first."
  echo
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV" || true
  echo
  echo "Mounted entries:"
  findmnt -rn | grep -F "$DEV" || true
  exit 1
fi

echo "About to back up this whole disk:"
lsblk -o NAME,MODEL,SERIAL,RM,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV" || \
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV"
echo

read -r -p "Type exactly '$DEV' to continue: " CONFIRM
if [ "$CONFIRM" != "$DEV" ]; then
  echo "Aborted."
  exit 1
fi

mkdir -p "$OUTDIR"

TS="$(date +%Y%m%d_%H%M%S)"
BASE="$(basename "$DEV")"
IMG="$OUTDIR/e1_sdcard_${BASE}_${TS}.img.gz"

echo "Backing up $DEV to compressed image $IMG ..."
dd if="$DEV" bs=4M status=progress iflag=fullblock | gzip -9 > "$IMG"

sync

echo "Generating SHA256 ..."
sha256sum "$IMG" | tee "$IMG.sha256"

echo "Saving partition evidence ..."
fdisk -l "$DEV" | tee "$OUTDIR/e1_partition_table_${BASE}_${TS}.txt"

lsblk -o NAME,MODEL,SERIAL,RM,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DEV" \
  | tee "$OUTDIR/e1_lsblk_${BASE}_${TS}.txt" || \
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DEV" \
  | tee "$OUTDIR/e1_lsblk_${BASE}_${TS}.txt"

echo
echo "Backup complete."
echo "Image:"
echo "  $IMG"
echo "SHA256:"
echo "  $IMG.sha256"
du -h "$IMG"