#!/bin/bash

# Usage: ./add_qemu_guest_agent.sh <cloud-image-path> <output-image-path>

set -e

if [ "$#" -ne 1 ] && [ "$#" -ne 2 ]; then
  echo "Usage: $0 <cloud-image-path> [output-image-path]"
  exit 1
fi

CLOUD_IMAGE=$1
if [ "$#" -eq 2 ]; then
  OUTPUT_IMAGE=$2
else
  OUTPUT_IMAGE=$1
fi

# Create a working directory
WORKDIR=$(mktemp -d)
MOUNTDIR=${WORKDIR}/mnt

mkdir -p ${MOUNTDIR}

# Load nbd module with max partitions
modprobe nbd max_part=16

# Find a free /dev/nbdX device
for dev in /dev/nbd*; do
  # Skip partition devices
  if [[ "$dev" =~ p[0-9]+$ ]]; then
    continue
  fi
  # Check if device is in use
  if ! fuser "$dev" >/dev/null 2>&1; then
    NBD_DEVICE=$dev
    break
  fi
done

if [ -z "$NBD_DEVICE" ]; then
  echo "No free /dev/nbd device found"
  exit 1
fi

echo "Using NBD device: $NBD_DEVICE"
qemu-nbd -c "$NBD_DEVICE" ${CLOUD_IMAGE}

# Wait for device to be ready
sleep 2

# Mount the root partition (assumed to be ${NBD_DEVICE}p1)
mount ${NBD_DEVICE}p1 ${MOUNTDIR}

# Mount necessary filesystems for chroot
mount --bind /dev ${MOUNTDIR}/dev
mount --bind /proc ${MOUNTDIR}/proc
mount --bind /sys ${MOUNTDIR}/sys

# Remove dangling symlink if exists and copy resolv.conf for DNS resolution
if [ -L "${MOUNTDIR}/etc/resolv.conf" ]; then
  rm "${MOUNTDIR}/etc/resolv.conf"
fi
cp /etc/resolv.conf ${MOUNTDIR}/etc/resolv.conf

# Chroot and install qemu-guest-agent
chroot ${MOUNTDIR} /bin/bash -c "apt-get update && apt-get install -y qemu-guest-agent"

# Cleanup
umount ${MOUNTDIR}/dev
umount ${MOUNTDIR}/proc
umount ${MOUNTDIR}/sys
umount ${MOUNTDIR}

qemu-nbd -d ${NBD_DEVICE}

# Remove working directory
rm -rf ${WORKDIR}

echo "Modified image saved to ${OUTPUT_IMAGE}"
