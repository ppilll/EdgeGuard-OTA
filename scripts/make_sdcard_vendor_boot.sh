#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage:"
  echo "  sudo $0 /dev/sdb vendor/ebf6ull-s1-pro/u-boot-dtb.imx vendor/ebf6ull-s1-pro/zImage vendor/ebf6ull-s1-pro/imx6ull-mmc-npi.dtb"
  exit 1
fi

SD="$1"
UBOOT="$2"
KERNEL="$3"
DTB="$4"

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${PROJECT}/output/edgeguard-imx6ull"
ROOTFS_TAR="${OUT}/images/rootfs.tar"

BOOT_MNT="/mnt/edgeguard-boot"
ROOT_MNT="/mnt/edgeguard-rootfs"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: please run with sudo"
  exit 1
fi

for f in "$UBOOT" "$KERNEL" "$DTB" "$ROOTFS_TAR"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: file not found: $f"
    exit 1
  fi
done

if [ ! -b "$SD" ]; then
  echo "ERROR: block device not found: $SD"
  exit 1
fi

SD_BASE="$(basename "$SD")"

# Refuse partition paths like /dev/sdb1, /dev/mmcblk0p1, /dev/nvme0n1p1.
if [ -e "/sys/class/block/${SD_BASE}/partition" ]; then
  echo "ERROR: $SD is a partition, not a whole disk."
  echo "Please pass the whole SD card device, e.g. /dev/sdb, not /dev/sdb1."
  exit 1
fi

part_name() {
  local disk="$1"
  local idx="$2"

  if [[ "$disk" == /dev/mmcblk* || "$disk" == /dev/nvme* ]]; then
    echo "${disk}p${idx}"
  else
    echo "${disk}${idx}"
  fi
}

BOOT_PART="$(part_name "$SD" 1)"
ROOT_PART="$(part_name "$SD" 2)"

# Refuse to operate on the system root disk.
ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [ -n "$ROOT_SRC" ]; then
  ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
  if [ "$SD" = "$ROOT_DISK" ]; then
    echo "ERROR: $SD seems to be system disk. Refusing."
    exit 1
  fi
fi

unmount_sd_partitions() {
  # Unmount by known partition names first.
  umount "$BOOT_PART" 2>/dev/null || true
  umount "$ROOT_PART" 2>/dev/null || true

  # Unmount anything listed under the disk.
  while read -r p; do
    [ -n "$p" ] && umount "/dev/$p" 2>/dev/null || true
  done < <(lsblk -ln -o NAME "$SD" 2>/dev/null | tail -n +2 || true)

  # Unmount our mountpoints too, in case device names changed.
  umount "$BOOT_MNT" 2>/dev/null || true
  umount "$ROOT_MNT" 2>/dev/null || true
}

reread_partitions() {
  partprobe "$SD" || true
  udevadm settle || true
  sleep 2

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "Partition nodes are not visible yet; trying one more settle..."
    partprobe "$SD" || true
    udevadm settle || true
    sleep 3
  fi

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "ERROR: partitions not visible:"
    lsblk "$SD" || true
    echo "Expected: $BOOT_PART and $ROOT_PART"
    exit 1
  fi
}

echo "DANGER: this will ERASE $SD"
echo
echo "SD card:"
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT "$SD" || true
echo
echo "U-Boot : $UBOOT"
echo "Kernel : $KERNEL"
echo "DTB    : $DTB"
echo "Rootfs : $ROOTFS_TAR"
echo
read -r -p "Type exactly 'ERASE ${SD}' to continue: " CONFIRM

if [ "$CONFIRM" != "ERASE $SD" ]; then
  echo "Aborted."
  exit 1
fi

echo "[1/11] Unmount old partitions..."
unmount_sd_partitions

echo "[2/11] Wipe old beginning area..."
wipefs -a "$SD" || true
dd if=/dev/zero of="$SD" bs=1M count=32 conv=fsync status=progress
sync

echo "[3/11] Create MBR partitions..."
sfdisk "$SD" <<'SFDISK_EOF'
label: dos
unit: sectors

start=2048, size=262144, type=c, bootable
start=264192, type=83
SFDISK_EOF

reread_partitions

echo "New partition layout:"
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT "$SD" || true

echo "[4/11] Unmount possible desktop automounts..."
unmount_sd_partitions

echo "[5/11] Wipe partition signatures..."
wipefs -a "$BOOT_PART" || true
wipefs -a "$ROOT_PART" || true
sync

echo "[6/11] Format partitions..."
mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -F -L rootfs "$ROOT_PART"
sync

echo "[7/11] Copy kernel and dtb to BOOT partition..."
unmount_sd_partitions
reread_partitions

mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

cp "$KERNEL" "$BOOT_MNT/zImage"
cp "$DTB" "$BOOT_MNT/edgeguard.dtb"

sync

echo "BOOT partition content:"
ls -lh "$BOOT_MNT"

umount "$BOOT_MNT"
sync

echo "[8/11] Extract Buildroot rootfs..."
unmount_sd_partitions
reread_partitions

mkdir -p "$ROOT_MNT"
mount "$ROOT_PART" "$ROOT_MNT"

tar -xf "$ROOTFS_TAR" -C "$ROOT_MNT"

sync

echo "Rootfs top level:"
ls -lh "$ROOT_MNT" | head

umount "$ROOT_MNT"
sync

echo "[9/11] Write U-Boot raw image as final step..."
unmount_sd_partitions

# Official-style command:
# dd default block size is 512 bytes, so seek=2 means 1024-byte offset.
dd iflag=dsync oflag=dsync if="$UBOOT" of="$SD" seek=2 status=progress
sync

echo "[10/11] Verify U-Boot raw area and BOOT files..."
reread_partitions

UBOOT_SIZE="$(stat -c%s "$UBOOT")"
UBOOT_BLOCKS=$(( (UBOOT_SIZE + 511) / 512 ))

dd if="$SD" of=/tmp/edgeguard-uboot-from-sd.imx bs=512 skip=2 count="$UBOOT_BLOCKS" status=none

if cmp -n "$UBOOT_SIZE" "$UBOOT" /tmp/edgeguard-uboot-from-sd.imx; then
  echo "OK: U-Boot raw area matches."
else
  echo "ERROR: U-Boot raw area does not match!"
  exit 1
fi

unmount_sd_partitions
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

echo "BOOT partition content after U-Boot write:"
ls -lh "$BOOT_MNT"

if cmp "$KERNEL" "$BOOT_MNT/zImage"; then
  echo "OK: zImage matches."
else
  echo "ERROR: zImage mismatch or missing!"
  umount "$BOOT_MNT" || true
  exit 1
fi

if cmp "$DTB" "$BOOT_MNT/edgeguard.dtb"; then
  echo "OK: DTB matches."
else
  echo "ERROR: DTB mismatch or missing!"
  umount "$BOOT_MNT" || true
  exit 1
fi

umount "$BOOT_MNT"
sync

echo "[11/11] Final sync and layout..."
unmount_sd_partitions
sync

lsblk -f "$SD" || true

echo
echo "SD card ready."
echo "Boot partition: $BOOT_PART"
echo "Root partition: $ROOT_PART"
echo
echo "Manual U-Boot commands:"
echo "  mmc dev 0"
echo "  mmc rescan"
echo "  fatls mmc 0:1"
echo "  ext4ls mmc 0:2 /"
echo "  fatload mmc 0:1 0x80800000 zImage"
echo "  fatload mmc 0:1 0x83000000 edgeguard.dtb"
echo "  setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4'"
echo "  bootz 0x80800000 - 0x83000000"
echo
echo "Before removing the SD card, recommended:"
echo "  sudo udisksctl power-off -b $SD"
echo "If udisksctl is unavailable, wait a few seconds after sync before unplugging."