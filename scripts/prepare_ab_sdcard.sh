#!/usr/bin/env bash
set -Eeuo pipefail

# EdgeGuard OTA E3 A/B SD-card preparation script
#
# Layout:
#   p1 BOOT      128 MiB FAT32
#   p2 rootfs_A  512 MiB ext4 <- e3-bootstrap v0.2.0
#   p3 rootfs_B  512 MiB ext4 <- e3 v0.3.0
#   p4 data      remaining space, ext4
#
# Script location expected:
#   /home/liu/work/EdgeGuard_OTA/scripts/prepare_ab_sdcard.sh

usage() {
  cat <<USAGE_EOF
Usage:
  sudo $0 <sd-device> <u-boot.imx> <zImage> <device-tree.dtb>

Example:
  sudo $0 \\
    /dev/sdb \\
    vendor/ebf6ull-s1-pro/u-boot-dtb.imx \\
    vendor/ebf6ull-s1-pro/zImage \\
    vendor/ebf6ull-s1-pro/imx6ull-mmc-npi.dtb

Notes:
  * Relative image paths are resolved against the project root.
  * The whole SD-card device must be supplied, for example /dev/sdb,
    not a partition such as /dev/sdb1.
  * This script irreversibly erases the selected device.
USAGE_EOF
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo/root privileges." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "${SCRIPT_DIR}/.." && pwd)"

resolve_project_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)  printf '%s/%s\n' "$PROJECT" "$path" ;;
  esac
}

SD_INPUT="$1"
UBOOT="$(resolve_project_path "$2")"
KERNEL="$(resolve_project_path "$3")"
DTB="$(resolve_project_path "$4")"

ROOTFS_A_TAR="${PROJECT}/releases/e3-v0.3.0/rootfs.tar"
ROOTFS_B_TAR="${PROJECT}/releases/e3-v0.3.1/rootfs.tar"

BOOT_MNT="/mnt/edgeguard-boot"
ROOTFS_A_MNT="/mnt/edgeguard-rootfs-a"
ROOTFS_B_MNT="/mnt/edgeguard-rootfs-b"
DATA_MNT="/mnt/edgeguard-data"

# Partition geometry, in 512-byte sectors.
BOOT_START=2048
BOOT_SIZE=262144
ROOTFS_A_START=264192
ROOTFS_A_SIZE=1048576
ROOTFS_B_START=1312768
ROOTFS_B_SIZE=1048576
DATA_START=2361344
MIN_DATA_SIZE=65536       # Require at least 32 MiB for p4.
UBOOT_OFFSET_SECTORS=2    # 2 * 512 = 1024-byte raw offset.
SECTOR_SIZE=512

VERIFY_UBOOT_TMP=""

required_commands=(
  awk basename blockdev cat cmp cp dd df fdisk findmnt grep head id
  lsblk mkdir mkfs.ext4 mkfs.vfat mktemp mount partprobe readlink rm sfdisk
  sha256sum sleep stat sync tail tar udevadm umount wipefs
)

for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

for file in "$UBOOT" "$KERNEL" "$DTB" "$ROOTFS_A_TAR" "$ROOTFS_B_TAR"; do
  if [ ! -f "$file" ]; then
    echo "ERROR: file not found: $file" >&2
    exit 1
  fi
done

if [ ! -b "$SD_INPUT" ]; then
  echo "ERROR: block device not found: $SD_INPUT" >&2
  exit 1
fi

# Resolve /dev/disk/by-* links so partition naming and safety checks use the
# actual kernel block-device name.
SD="$(readlink -f "$SD_INPUT")"
SD_BASE="$(basename "$SD")"

# Refuse partition paths such as /dev/sdb1 or /dev/mmcblk0p1.
if [ -e "/sys/class/block/${SD_BASE}/partition" ]; then
  echo "ERROR: $SD is a partition, not a whole disk." >&2
  echo "Pass the whole SD-card device, for example /dev/sdb." >&2
  exit 1
fi

part_name() {
  local disk="$1"
  local index="$2"

  if [[ "$disk" == /dev/mmcblk* || "$disk" == /dev/nvme* ]]; then
    printf '%sp%s\n' "$disk" "$index"
  else
    printf '%s%s\n' "$disk" "$index"
  fi
}

BOOT_PART="$(part_name "$SD" 1)"
ROOTFS_A_PART="$(part_name "$SD" 2)"
ROOTFS_B_PART="$(part_name "$SD" 3)"
DATA_PART="$(part_name "$SD" 4)"

# Refuse to operate on the host system disk.
ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
  ROOT_DISK_NAME="$(lsblk -sno NAME "$ROOT_SRC" 2>/dev/null | tail -n1 || true)"
  if [ -n "$ROOT_DISK_NAME" ] && [ "$SD" = "/dev/${ROOT_DISK_NAME}" ]; then
    echo "ERROR: $SD appears to be the host system disk; refusing." >&2
    exit 1
  fi
fi

validate_rootfs_archive() {
  local archive="$1"
  local label="$2"
  local listing

  echo "Checking ${label} archive: $archive"

  # tar -tf validates that the archive can be read. Capture the member list so
  # obviously unsafe absolute or parent-traversal paths can be rejected before
  # the SD card is erased.
  if ! listing="$(tar -tf "$archive")"; then
    echo "ERROR: cannot read ${label} archive: $archive" >&2
    exit 1
  fi

  if printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "ERROR: ${label} archive contains an unsafe absolute or '..' path." >&2
    exit 1
  fi

  if ! printf '%s\n' "$listing" | grep -Eq '^\./etc/?$|^etc/?$|^\./etc/|^etc/'; then
    echo "ERROR: ${label} archive does not appear to contain a top-level /etc." >&2
    echo "The archive may contain an extra enclosing directory." >&2
    exit 1
  fi
}

validate_rootfs_archive "$ROOTFS_A_TAR" "rootfs_A"
validate_rootfs_archive "$ROOTFS_B_TAR" "rootfs_B"

# Ensure the U-Boot raw image cannot reach the first partition at sector 2048.
UBOOT_SIZE_BYTES="$(stat -c%s "$UBOOT")"
UBOOT_END_BYTES=$((UBOOT_OFFSET_SECTORS * SECTOR_SIZE + UBOOT_SIZE_BYTES))
BOOT_START_BYTES=$((BOOT_START * SECTOR_SIZE))
if [ "$UBOOT_END_BYTES" -gt "$BOOT_START_BYTES" ]; then
  echo "ERROR: U-Boot image would overlap p1." >&2
  echo "  U-Boot end: ${UBOOT_END_BYTES} bytes" >&2
  echo "  p1 start  : ${BOOT_START_BYTES} bytes" >&2
  exit 1
fi

# Require enough space for p1/p2/p3 and a small p4 data partition.
SD_SECTORS="$(blockdev --getsz "$SD")"
MIN_SD_SECTORS=$((DATA_START + MIN_DATA_SIZE))
if [ "$SD_SECTORS" -lt "$MIN_SD_SECTORS" ]; then
  echo "ERROR: $SD is too small for the requested layout." >&2
  echo "  Available sectors: $SD_SECTORS" >&2
  echo "  Required sectors : $MIN_SD_SECTORS" >&2
  exit 1
fi

unmount_sd_partitions() {
  umount "$BOOT_PART" 2>/dev/null || true
  umount "$ROOTFS_A_PART" 2>/dev/null || true
  umount "$ROOTFS_B_PART" 2>/dev/null || true
  umount "$DATA_PART" 2>/dev/null || true

  while read -r part; do
    [ -n "$part" ] && umount "/dev/$part" 2>/dev/null || true
  done < <(lsblk -ln -o NAME "$SD" 2>/dev/null | tail -n +2 || true)

  umount "$BOOT_MNT" 2>/dev/null || true
  umount "$ROOTFS_A_MNT" 2>/dev/null || true
  umount "$ROOTFS_B_MNT" 2>/dev/null || true
  umount "$DATA_MNT" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  unmount_sd_partitions
  if [ -n "$VERIFY_UBOOT_TMP" ]; then
    rm -f "$VERIFY_UBOOT_TMP"
  fi
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reread_partitions() {
  partprobe "$SD" || true
  udevadm settle || true
  sleep 2

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOTFS_A_PART" ] || \
     [ ! -b "$ROOTFS_B_PART" ] || [ ! -b "$DATA_PART" ]; then
    echo "Partition nodes are not visible yet; trying again..."
    partprobe "$SD" || true
    udevadm settle || true
    sleep 3
  fi

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOTFS_A_PART" ] || \
     [ ! -b "$ROOTFS_B_PART" ] || [ ! -b "$DATA_PART" ]; then
    echo "ERROR: expected partition nodes are missing:" >&2
    lsblk "$SD" || true
    printf '  %s\n  %s\n  %s\n  %s\n' \
      "$BOOT_PART" "$ROOTFS_A_PART" "$ROOTFS_B_PART" "$DATA_PART" >&2
    exit 1
  fi
}

verify_not_mounted() {
  if lsblk -nrpo NAME,MOUNTPOINTS "$SD" | \
      awk 'NF >= 2 { mounted=1 } END { exit mounted ? 0 : 1 }'; then
    echo "ERROR: one or more partitions are still mounted:" >&2
    lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS "$SD" || true
    exit 1
  fi
}

write_slot_file() {
  local root="$1"
  local slot="$2"

  mkdir -p "$root/etc"
  cat > "$root/etc/edgeguard_slot" <<SLOT_EOF
SLOT=$slot
SLOT_EOF
}

verify_rootfs_layout() {
  local root="$1"
  local label="$2"

  if [ ! -d "$root/etc" ]; then
    echo "ERROR: ${label} does not contain a top-level /etc after extraction." >&2
    exit 1
  fi

  if [ ! -e "$root/bin" ] && [ ! -e "$root/usr/bin" ]; then
    echo "WARN: ${label} contains neither /bin nor /usr/bin."
  fi
}

report_version_file() {
  local root="$1"
  local label="$2"

  echo "${label} /etc/edgeguard_version:"
  if [ -f "$root/etc/edgeguard_version" ]; then
    cat "$root/etc/edgeguard_version"
  else
    echo "WARN: ${label} has no /etc/edgeguard_version"
  fi
}

report_versions() {
  local root_a="$1"
  local root_b="$2"

  report_version_file "$root_a" "rootfs_A"
  report_version_file "$root_b" "rootfs_B"

  if [ -f "$root_a/etc/edgeguard_version" ] && \
     [ -f "$root_b/etc/edgeguard_version" ]; then
    if cmp -s "$root_a/etc/edgeguard_version" \
              "$root_b/etc/edgeguard_version"; then
      echo "WARN: A/B edgeguard_version files are identical."
    else
      echo "OK: A/B edgeguard_version files differ, as expected."
    fi
  fi
}

print_hashes() {
  echo "Input image SHA-256:"
  sha256sum "$UBOOT" "$KERNEL" "$DTB" "$ROOTFS_A_TAR" "$ROOTFS_B_TAR"
}

cat <<PLAN_EOF

DANGER: this operation will ERASE $SD

Project root : $PROJECT
SD device    : $SD
U-Boot       : $UBOOT
Kernel       : $KERNEL
DTB          : $DTB
rootfs_A     : $ROOTFS_A_TAR
rootfs_B     : $ROOTFS_B_TAR

Planned layout:
  p1 BOOT      128 MiB FAT32
  p2 rootfs_A  512 MiB ext4  <- v0.2.0 E3 bootstrap
  p3 rootfs_B  512 MiB ext4  <- v0.3.0 E3
  p4 data      remaining ext4

The script will overwrite:
  p2:/etc/edgeguard_slot with SLOT=A
  p3:/etc/edgeguard_slot with SLOT=B
PLAN_EOF

lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MODEL,MOUNTPOINTS "$SD" || true
print_hashes

echo
read -r -p "Type exactly 'ERASE ${SD}' to continue: " CONFIRM
if [ "$CONFIRM" != "ERASE $SD" ]; then
  echo "Aborted."
  exit 1
fi

echo "[1/14] Unmount existing SD-card partitions..."
unmount_sd_partitions
verify_not_mounted

echo "[2/14] Wipe old signatures and the first 32 MiB..."
wipefs -a "$SD" || true
dd if=/dev/zero of="$SD" bs=1M count=32 conv=fsync status=progress
sync

echo "[3/14] Create the MBR A/B partition table..."
sfdisk "$SD" <<SFDISK_EOF
label: dos
unit: sectors

start=${BOOT_START},     size=${BOOT_SIZE},     type=c,  bootable
start=${ROOTFS_A_START}, size=${ROOTFS_A_SIZE}, type=83
start=${ROOTFS_B_START}, size=${ROOTFS_B_SIZE}, type=83
start=${DATA_START},                            type=83
SFDISK_EOF

reread_partitions
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS "$SD" || true

echo "[4/14] Unmount possible desktop automounts..."
unmount_sd_partitions
verify_not_mounted

echo "[5/14] Remove stale partition signatures..."
wipefs -a "$BOOT_PART" || true
wipefs -a "$ROOTFS_A_PART" || true
wipefs -a "$ROOTFS_B_PART" || true
wipefs -a "$DATA_PART" || true
sync

echo "[6/14] Format all partitions..."
mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -F -L rootfs_A "$ROOTFS_A_PART"
mkfs.ext4 -F -L rootfs_B "$ROOTFS_B_PART"
mkfs.ext4 -F -L data "$DATA_PART"
sync

echo "[7/14] Copy the shared kernel and DTB to BOOT..."
unmount_sd_partitions
reread_partitions
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"
cp "$KERNEL" "$BOOT_MNT/zImage"
cp "$DTB" "$BOOT_MNT/edgeguard.dtb"
sync
ls -lh "$BOOT_MNT"
umount "$BOOT_MNT"
sync

echo "[8/14] Extract v0.2.0 E3 bootstrap into rootfs_A..."
unmount_sd_partitions
reread_partitions
mkdir -p "$ROOTFS_A_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"
tar --numeric-owner --same-permissions -xf "$ROOTFS_A_TAR" -C "$ROOTFS_A_MNT"
verify_rootfs_layout "$ROOTFS_A_MNT" "rootfs_A"
sync
df -h "$ROOTFS_A_MNT"
df -i "$ROOTFS_A_MNT"
umount "$ROOTFS_A_MNT"
sync

echo "[9/14] Extract v0.3.0 E3 into rootfs_B..."
unmount_sd_partitions
reread_partitions
mkdir -p "$ROOTFS_B_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"
tar --numeric-owner --same-permissions -xf "$ROOTFS_B_TAR" -C "$ROOTFS_B_MNT"
verify_rootfs_layout "$ROOTFS_B_MNT" "rootfs_B"
sync
df -h "$ROOTFS_B_MNT"
df -i "$ROOTFS_B_MNT"
umount "$ROOTFS_B_MNT"
sync

echo "[10/14] Write A/B slot identity files and report versions..."
unmount_sd_partitions
reread_partitions
mkdir -p "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"
write_slot_file "$ROOTFS_A_MNT" A
write_slot_file "$ROOTFS_B_MNT" B
report_versions "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
echo "rootfs_A slot: $(cat "$ROOTFS_A_MNT/etc/edgeguard_slot")"
echo "rootfs_B slot: $(cat "$ROOTFS_B_MNT/etc/edgeguard_slot")"
sync
umount "$ROOTFS_A_MNT"
umount "$ROOTFS_B_MNT"
sync

echo "[11/14] Verify and initialize the data partition..."
unmount_sd_partitions
reread_partitions
mkdir -p "$DATA_MNT"
mount "$DATA_PART" "$DATA_MNT"
cat > "$DATA_MNT/README_E3_DATA.txt" <<DATA_EOF
EdgeGuard E3 A/B upgrade-test data partition.
rootfs_A: rootfs-v0.2.0-e3-bootstrap.tar
rootfs_B: rootfs-v0.3.0-e3.tar
DATA_EOF
sync
ls -lh "$DATA_MNT"
umount "$DATA_MNT"
sync

echo "[12/14] Write U-Boot to the 1024-byte raw offset..."
unmount_sd_partitions
verify_not_mounted
dd iflag=dsync oflag=dsync if="$UBOOT" of="$SD" seek="$UBOOT_OFFSET_SECTORS" status=progress
sync

echo "[13/14] Verify U-Boot, BOOT files, slots, and versions..."
reread_partitions

VERIFY_UBOOT_TMP="$(mktemp /tmp/edgeguard-uboot-from-sd.XXXXXX)"
UBOOT_BLOCKS=$(( (UBOOT_SIZE_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE ))
dd if="$SD" of="$VERIFY_UBOOT_TMP" bs="$SECTOR_SIZE" \
   skip="$UBOOT_OFFSET_SECTORS" count="$UBOOT_BLOCKS" status=none

if cmp -n "$UBOOT_SIZE_BYTES" "$UBOOT" "$VERIFY_UBOOT_TMP"; then
  echo "OK: U-Boot raw area matches."
else
  echo "ERROR: U-Boot raw area does not match." >&2
  exit 1
fi

unmount_sd_partitions
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

if cmp "$KERNEL" "$BOOT_MNT/zImage"; then
  echo "OK: zImage matches."
else
  echo "ERROR: zImage mismatch or missing." >&2
  exit 1
fi

if cmp "$DTB" "$BOOT_MNT/edgeguard.dtb"; then
  echo "OK: DTB matches."
else
  echo "ERROR: DTB mismatch or missing." >&2
  exit 1
fi

umount "$BOOT_MNT"
sync

mkdir -p "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"

if grep -qx 'SLOT=A' "$ROOTFS_A_MNT/etc/edgeguard_slot"; then
  echo "OK: rootfs_A slot marker matches."
else
  echo "ERROR: rootfs_A slot marker mismatch." >&2
  exit 1
fi

if grep -qx 'SLOT=B' "$ROOTFS_B_MNT/etc/edgeguard_slot"; then
  echo "OK: rootfs_B slot marker matches."
else
  echo "ERROR: rootfs_B slot marker mismatch." >&2
  exit 1
fi

report_versions "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
umount "$ROOTFS_A_MNT"
umount "$ROOTFS_B_MNT"
sync

echo "[14/14] Final sync and partition report..."
unmount_sd_partitions
sync
lsblk -f "$SD" || true
fdisk -l "$SD" || true

cat <<DONE_EOF

SD card is ready.

BOOT partition    : $BOOT_PART
rootfs_A partition: $ROOTFS_A_PART
rootfs_A source   : $ROOTFS_A_TAR
rootfs_B partition: $ROOTFS_B_PART
rootfs_B source   : $ROOTFS_B_TAR
data partition    : $DATA_PART

Manual U-Boot boot commands for A:
  mmc dev 0
  mmc rescan
  fatload mmc 0:1 0x80800000 zImage
  fatload mmc 0:1 0x83000000 edgeguard.dtb
  setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4'
  bootz 0x80800000 - 0x83000000

Manual U-Boot boot commands for B:
  mmc dev 0
  mmc rescan
  fatload mmc 0:1 0x80800000 zImage
  fatload mmc 0:1 0x83000000 edgeguard.dtb
  setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4'
  bootz 0x80800000 - 0x83000000

Before unplugging the card, preferably run:
  sudo udisksctl power-off -b $SD
DONE_EOF
