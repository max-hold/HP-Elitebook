#!/bin/bash
set -e

VM_NAME="alpine-firefox"
DISK="alpine-vm.qcow2"
SEED="seed.iso"
MEMORY=2048
CPUS=2

# === 1. Download Alpine cloud-init image (NoCloud variant) ===
IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2"
if [ ! -f base.qcow2 ]; then
    echo "Downloading Alpine cloud image..."
    wget -O base.qcow2 "$IMAGE_URL"
fi

# Resize/copy for VM
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 "$DISK" 10G || true  # grow if needed

ssh-keygen -t ed25519
PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)

# === 2. Cloud-init user-data (main config) ===
cat > user-data << 'EOF'
#cloud-config

hostname: alpine-vm
fqdn: alpine-vm.local

manage_etc_hosts: true

users:
  - default

  - name: root
    lock_passwd: false

  - name: max
    groups: wheel
    shell: /bin/ash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${PUB_KEY}

ssh_pwauth: true
disable_root: false

chpasswd:
  list: |
    root:rootpassword
    max:maxpassword
  expire: false

package_update: true
package_upgrade: true

packages:
  - openrc
  - dbus
  - elogind
  - polkit-elogind
  - firefox
  - unclutter-xfixes
  - openbox
  - ttf-dejavu
  - ttf-liberation
  - font-noto
  - font-noto-cjk
  - font-noto-extra
  - ttf-freefont
  - udev
  - sudo
  - doas
  - xset
  - xrandr

runcmd:
  - rc-update add dbus
  - rc-update add udev
  - rc-update add udev-trigger
  - rc-update add udev-settle
  - rc-update add local

  # Setup Xorg properly
  - setup-xorg-base
  - addgroup max video
  - addgroup max input
  - addgroup max audio

  - mkdir -p /home/max/.config/openbox
  - chown -R max:max /home/max

  # Minimal Openbox config - no menu if possible
  - |
    cat > /home/max/.config/openbox/rc.xml << 'EORC'
    <openbox_config>
      <desktops><number>1</number></desktops>
      <keyboard><chainQuitKey>C-g</chainQuitKey></keyboard>
    </openbox_config>
    EORC

  # Autostart ONLY Firefox (kiosk mode)
  - |
    cat > /home/max/.config/openbox/autostart << 'EOA'
    xset -dpms
    xset s off
    exec firefox --kiosk --no-remote https://www.example.com
    EOA
  - chmod +x /home/max/.config/openbox/autostart
  - chown max:max /home/max/.config/openbox/autostart

  # .xinitrc
  - |
    cat > /home/max/.xinitrc << 'EOX'
    exec openbox-session
    EOX
  - chmod +x /home/max/.xinitrc
  - chown max:max /home/max/.xinitrc

  # Proper autologin on tty1 + startx
  - apk add util-linux  # for agetty if needed
  - |
    sed -i 's|^tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/agetty --autologin max --noclear 38400 tty1 linux|' /etc/inittab
    sed -i 's|^#tty1|tty1|' /etc/inittab || true

  # Final cleanup and ensure services
  - rc-update add local
  - echo "exec startx" >> /home/max/.profile
  - reboot
EOF

# === 3. Meta-data ===
cat > meta-data << EOF
instance-id: iid-${VM_NAME}
local-hostname: ${VM_NAME}
EOF

# === 4. Create seed ISO ===
cloud-localds "$SEED" user-data meta-data

# === 5. Launch QEMU ===
echo "Starting VM. Connect via graphical window. SSH if enabled: user max"
qemu-system-x86_64 \
  -name "$VM_NAME" \
  -m "$MEMORY" \
  -smp "$CPUS" \
  -cpu host \
  -enable-kvm \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$SEED",if=virtio,format=raw,readonly=on \
  -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
  -vga virtio \
  -display gtk,gl=on \
  -device virtio-gpu-pci \
  -boot c \
  -daemonize || true  # Remove -daemonize for foreground

echo "VM launched. Monitor with 'ps aux | grep qemu' or virt-viewer."
echo "SSH: ssh -p 2222 max@localhost (after first boot)"
