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
  -vga none \
  -device virtio-gpu-pci \
  -spice port=5930,disable-ticketing=on \
  -device virtio-serial-pci \
  -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 \
  -chardev spicevmc,id=spicechannel0,name=vdagent \
  \
  -usb \
  -device usb-tablet \
  \
  -no-reboot \
  "$@"


# Run the VNC
sudo apt install virt-viewer
remote-viewer spice://localhost:5930

