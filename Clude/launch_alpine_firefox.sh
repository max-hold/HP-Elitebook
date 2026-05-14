#!/bin/bash
# launch_alpine_firefox.sh

VM_NAME="alpine-firefox-kiosk"
DISK="alpine-vm.qcow2"
MEMORY=4096
CPUS=4

echo "Starting $VM_NAME (Persistent mode - no cloud-init seed)"

qemu-system-x86_64 \
  -name "$VM_NAME" \
  -m "$MEMORY" \
  -smp "$CPUS" \
  -cpu host \
  -enable-kvm \
  \
  -drive file="$DISK",if=virtio,format=qcow2,discard=unmap \
  \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::2222-:22 \
  \
  -device virtio-gpu-pci \
  -vga virtio \
  -display gtk,gl=on \
  \
  -boot c \
  -usb \
  -device usb-tablet \
  \
  -no-reboot \
  "$@"

# Optional flags you can add:
# -full-screen
# -spice port=5930,disable-ticketing=on   → then use virt-viewer spicy
