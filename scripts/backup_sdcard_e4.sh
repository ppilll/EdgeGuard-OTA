#!/usr/bin/env bash
#
# EdgeGuard E4 compressed SD card full-image backup script.
#
# Compatible target:
#   Ubuntu 18.04 / util-linux 2.31.1
#
# Backup format:
#   Whole-card raw image, compressed on the fly:
#     dd if=/dev/sdX bs=4M | gzip -c > edgeguard_e4_sdcard_<timestamp>.img.gz
#
# This is still a full block-level SD-card backup. It is only compressed
# to save host disk space.
#
# Safety:
#   - Do not use lsblk MOUNTPOINTS.
#   - Do not require lsblk PATH.
#   - Dynamically skip unsupported lsblk columns.
#   - Refuse partitions; require a whole disk.
#   - Refuse mounted SD-card partitions.
#   - Try to refuse the host root disk.
#   - Require explicit confirmation before dd.
#

set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  Detect disks only:
    $0 --detect

  Back up a whole SD card as compressed image:
    sudo $0 --device /dev/sdX --confirm EDGEGUARD_E4_BACKUP

Examples:
    $0 --detect
    sudo $0 --device /dev/sdb --confirm EDGEGUARD_E4_BACKUP
    sudo $0 --device /dev/mmcblk0 --confirm EDGEGUARD_E4_BACKUP

Output:
    backups/e4_sdcard_<timestamp>/edgeguard_e4_sdcard_<timestamp>.img.gz

Restore example, DO NOT RUN unless you intentionally want to overwrite target disk:
    gzip -dc edgeguard_e4_sdcard_<timestamp>.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

Safety rules:
  - Pass the whole disk, not a partition.
  - Valid examples: /dev/sdb, /dev/mmcblk0
  - Invalid examples: /dev/sdb1, /dev/mmcblk0p1
  - The script refuses mounted devices.
  - The script tries to refuse the current host root disk.
  - The script requires --confirm EDGEGUARD_E4_BACKUP before dd.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE=""
DEV=""
CONFIRM=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --detect)
      MODE="detect"
      shift
      ;;
    --device)
      DEV="${2:-}"
      MODE="backup"
      shift 2
      ;;
    --confirm)
      CONFIRM="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$MODE" ] || {
  usage
  exit 2
}

for cmd in lsblk blkid findmnt awk sed grep tee date sync sha256sum gzip; do
  require_cmd "$cmd"
done

if [ "$MODE" = "backup" ]; then
  for cmd in fdisk sfdisk dd blockdev readlink; do
    require_cmd "$cmd"
  done
fi

lsblk_supports_col() {
  local col="$1"
  lsblk -dn -o "$col" >/dev/null 2>&1
}

build_lsblk_cols() {
  local cols=()
  local col

  for col in "$@"; do
    if lsblk_supports_col "$col"; then
      cols+=("$col")
    else
      warn "lsblk column not supported on this host, skip: $col"
    fi
  done

  if [ "${#cols[@]}" -eq 0 ]; then
    die "no supported lsblk columns from requested set"
  fi

  local IFS=,
  echo "${cols[*]}"
}

safe_lsblk_all() {
  local cols
  cols="$(build_lsblk_cols NAME KNAME PKNAME TYPE SIZE FSTYPE LABEL UUID PARTUUID MODEL SERIAL RM RO MOUNTPOINT)"
  lsblk -o "$cols"
}

safe_lsblk_dev() {
  local dev="$1"
  local cols
  cols="$(build_lsblk_cols NAME KNAME PKNAME TYPE SIZE FSTYPE LABEL UUID PARTUUID MODEL SERIAL RM RO MOUNTPOINT)"
  lsblk -o "$cols" "$dev"
}

safe_lsblk_disks_only() {
  local cols
  cols="$(build_lsblk_cols NAME TYPE SIZE MODEL SERIAL RM RO)"
  lsblk -d -o "$cols"
}

udev_settle_if_available() {
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
}

detect_mode() {
  cd "$PROJECT_DIR"

  echo "===== E4 SD CARD READ-ONLY DETECT BEGIN ====="
  echo "[time] $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "[project] $PROJECT_DIR"

  echo
  echo "===== lsblk version ====="
  lsblk --version || true

  echo
  echo "===== lsblk supported columns hint ====="
  lsblk --help | sed -n '/Available output columns:/,$p' | sed -n '1,120p' || true

  echo
  echo "===== udev settle ====="
  udev_settle_if_available

  echo
  echo "===== lsblk full, compatibility-safe columns ====="
  safe_lsblk_all

  echo
  echo "===== blkid ====="
  blkid || true

  echo
  echo "===== root filesystem ====="
  findmnt / || true

  echo
  echo "===== candidate whole disks ====="
  safe_lsblk_disks_only

  echo
  echo "===== mount table lines for removable/card-like devices, best effort ====="
  mount | grep -E '/dev/sd|/dev/mmcblk|/dev/nvme' || true

  echo
  echo "===== E4 SD CARD READ-ONLY DETECT END ====="
}

is_whole_disk() {
  local dev="$1"
  local typ

  typ="$(lsblk -dn -o TYPE "$dev" 2>/dev/null | head -n 1 || true)"
  [ "$typ" = "disk" ]
}

part_dev() {
  local dev="$1"
  local idx="$2"

  case "$dev" in
    /dev/mmcblk*|/dev/nvme*n*|/dev/loop*)
      echo "${dev}p${idx}"
      ;;
    *)
      echo "${dev}${idx}"
      ;;
  esac
}

check_not_host_root_disk() {
  local dev="$1"
  local root_src
  local root_pk

  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

  echo "Host root source: ${root_src:-unknown}"

  if [ -n "$root_src" ]; then
    if [ "$root_src" = "$dev" ]; then
      die "refusing to back up the host root device: $dev"
    fi

    root_pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n 1 || true)"
    if [ -n "$root_pk" ] && [ "/dev/$root_pk" = "$dev" ]; then
      die "refusing to back up host root parent disk: $dev"
    fi
  fi

  if findmnt -n -o SOURCE / 2>/dev/null | grep -qE '^/dev/(sda|vda|nvme0n1)'; then
    case "$dev" in
      /dev/sda|/dev/vda|/dev/nvme0n1)
        die "refusing likely host system disk: $dev"
        ;;
    esac
  fi
}

check_partitions_exist() {
  local dev="$1"
  local p
  local idx

  for idx in 1 2 3 4; do
    p="$(part_dev "$dev" "$idx")"
    [ -b "$p" ] || die "missing expected partition: $p"
  done
}

blkid_value() {
  local key="$1"
  local dev="$2"
  blkid -o value -s "$key" "$dev" 2>/dev/null || true
}

check_edgeguard_layout() {
  local dev="$1"

  local p1 p2 p3 p4
  local t1 t2 t3 t4
  local l1 l4

  p1="$(part_dev "$dev" 1)"
  p2="$(part_dev "$dev" 2)"
  p3="$(part_dev "$dev" 3)"
  p4="$(part_dev "$dev" 4)"

  t1="$(blkid_value TYPE "$p1")"
  t2="$(blkid_value TYPE "$p2")"
  t3="$(blkid_value TYPE "$p3")"
  t4="$(blkid_value TYPE "$p4")"

  l1="$(blkid_value LABEL "$p1")"
  l4="$(blkid_value LABEL "$p4")"

  echo "===== EDGEGUARD PARTITION LAYOUT CHECK ====="
  echo "p1=$p1 TYPE=${t1:-unknown} LABEL=${l1:-none}"
  echo "p2=$p2 TYPE=${t2:-unknown}"
  echo "p3=$p3 TYPE=${t3:-unknown}"
  echo "p4=$p4 TYPE=${t4:-unknown} LABEL=${l4:-none}"

  [ "$t1" = "vfat" ] || die "$p1 should be vfat BOOT partition, got: ${t1:-unknown}"
  [ "$t2" = "ext4" ] || die "$p2 should be ext4 rootfs_A, got: ${t2:-unknown}"
  [ "$t3" = "ext4" ] || die "$p3 should be ext4 rootfs_B, got: ${t3:-unknown}"
  [ "$t4" = "ext4" ] || die "$p4 should be ext4 data partition, got: ${t4:-unknown}"

  if [ "$l1" != "BOOT" ]; then
    warn "$p1 label is not BOOT: ${l1:-none}"
  fi

  if [ "$l4" != "data" ]; then
    warn "$p4 label is not data: ${l4:-none}"
  fi
}

check_no_mounts_under_device() {
  local dev="$1"
  local mount_lines

  mount_lines="$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | awk 'NF {print}' || true)"

  echo "===== MOUNT CHECK ====="
  if [ -n "$mount_lines" ]; then
    echo "$mount_lines"
    die "one or more partitions under $dev are mounted; unmount them before backup"
  fi

  echo "OK: no mounted partitions detected under $dev"
}

write_restore_commands() {
  local outdir="$1"
  local img_gz="$2"

  cat > "${outdir}/restore_commands.txt" <<RESTORE
# EdgeGuard E4 compressed SD-card image restore notes.
#
# DANGER:
#   The following commands overwrite the target disk completely.
#   Replace /dev/sdX with the correct whole SD-card device.
#   Do not pass a partition such as /dev/sdX1.

# 1. Verify gzip archive:
gzip -t "$(basename "$img_gz")"

# 2. Verify compressed image checksum:
sha256sum -c "$(basename "$img_gz").sha256"

# 3. Restore to SD card:
gzip -dc "$(basename "$img_gz")" | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

# 4. Flush writes:
sync
RESTORE
}

backup_mode() {
  cd "$PROJECT_DIR"

  [ -n "$DEV" ] || die "missing --device"
  [ "$CONFIRM" = "EDGEGUARD_E4_BACKUP" ] || die "missing required confirmation: --confirm EDGEGUARD_E4_BACKUP"

  if [ "$(id -u)" -ne 0 ]; then
    die "backup mode must run as root, for example: sudo $0 --device $DEV --confirm EDGEGUARD_E4_BACKUP"
  fi

  DEV="$(readlink -f "$DEV")"

  [ -b "$DEV" ] || die "not a block device: $DEV"
  is_whole_disk "$DEV" || die "$DEV is not a whole disk according to lsblk TYPE=disk"

  echo "===== E4 SD CARD COMPRESSED BACKUP PRECHECK BEGIN ====="
  echo "[time] $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "[project] $PROJECT_DIR"
  echo "[device] $DEV"

  udev_settle_if_available

  echo
  echo "===== DEVICE SUMMARY ====="
  safe_lsblk_dev "$DEV"

  echo
  echo "===== HOST ROOT DISK CHECK ====="
  check_not_host_root_disk "$DEV"

  echo
  echo "===== PARTITION EXISTENCE CHECK ====="
  check_partitions_exist "$DEV"
  echo "OK: expected p1/p2/p3/p4 exist"

  echo
  check_edgeguard_layout "$DEV"

  echo
  check_no_mounts_under_device "$DEV"

  local ts outdir img_gz log_file dev_bytes compressor
  ts="$(date +%Y%m%d_%H%M%S)"
  outdir="backups/e4_sdcard_${ts}"
  img_gz="${outdir}/edgeguard_e4_sdcard_${ts}.img.gz"
  log_file="${outdir}/backup.log"
  dev_bytes="$(blockdev --getsize64 "$DEV")"

  mkdir -p "$outdir"

  exec > >(tee "$log_file") 2>&1

  echo "===== E4 SD CARD COMPRESSED FULL BACKUP BEGIN ====="
  echo "[time] $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "[project] $PROJECT_DIR"
  echo "[device] $DEV"
  echo "[device bytes] $dev_bytes"
  echo "[output dir] $outdir"
  echo "[compressed image] $img_gz"
  echo "[compression] gzip -1"
  echo
  echo "Note: this is a full raw SD-card image compressed on the fly."
  echo "Note: compression ratio depends on actual data and whether free space contains zeroes."

  echo
  echo "===== SAVE METADATA ====="
  safe_lsblk_dev "$DEV" | tee "${outdir}/lsblk_device.txt"
  safe_lsblk_all | tee "${outdir}/lsblk_all.txt"
  blkid | tee "${outdir}/blkid_all.txt"
  findmnt | tee "${outdir}/findmnt.txt"
  fdisk -l "$DEV" | tee "${outdir}/fdisk.txt"
  sfdisk -d "$DEV" | tee "${outdir}/sfdisk.dump"

  echo
  echo "===== /dev/disk links, best effort ====="
  {
    ls -l /dev/disk/by-id 2>/dev/null || true
    echo
    ls -l /dev/disk/by-label 2>/dev/null || true
    echo
    ls -l /dev/disk/by-partuuid 2>/dev/null || true
    echo
    ls -l /dev/disk/by-uuid 2>/dev/null || true
  } | tee "${outdir}/dev_disk_links.txt"

  echo
  echo "===== START COMPRESSED FULL IMAGE BACKUP ====="
  echo "Input device: $DEV"
  echo "Output gzip image: $img_gz"

  if dd --help 2>/dev/null | grep -q 'status=progress'; then
    dd if="$DEV" bs=4M status=progress | gzip -1 -c > "$img_gz"
  else
    dd if="$DEV" bs=4M | gzip -1 -c > "$img_gz"
  fi

  sync

  echo
  echo "===== VERIFY GZIP ARCHIVE ====="
  gzip -t "$img_gz"
  echo "OK: gzip archive test passed"

  echo
  echo "===== SHA256 OF COMPRESSED IMAGE ====="
  sha256sum "$img_gz" | tee "${img_gz}.sha256"

  echo
  echo "===== SIZE SUMMARY ====="
  ls -lh "$img_gz"
  printf 'raw_device_bytes=%s\n' "$dev_bytes" | tee "${outdir}/raw_device_size.txt"
  printf 'compressed_image_bytes=%s\n' "$(stat -c '%s' "$img_gz")" | tee "${outdir}/compressed_image_size.txt"

  echo
  echo "===== RESTORE COMMANDS ====="
  write_restore_commands "$outdir" "$img_gz"
  sed -n '1,120p' "${outdir}/restore_commands.txt"

  echo
  echo "===== BACKUP DONE ====="
  echo "Backup directory: $outdir"
  echo "Compressed image: $img_gz"
  echo "Log: $log_file"
  echo "SHA256 file: ${img_gz}.sha256"
}

case "$MODE" in
  detect)
    detect_mode
    ;;
  backup)
    backup_mode
    ;;
  *)
    die "invalid mode: $MODE"
    ;;
esac
