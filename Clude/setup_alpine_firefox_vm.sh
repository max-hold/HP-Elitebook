#!/bin/bash
# ==============================================================================
# setup_alpine_firefox_vm.sh
# Alpine Linux + Firefox Kiosk VM — QEMU/KVM with virtio-gpu GUI
#
# What this does:
#   1. Downloads Alpine cloud image
#   2. Configures cloud-init: installs Xorg + Mesa + Openbox + Firefox
#   3. Auto-logins user 'max' on tty1
#   4. Auto-starts Xorg → Openbox → Firefox kiosk (no intervention needed)
#
# First boot: cloud-init runs (~2-3 min), VM reboots automatically
# Second boot: QEMU window opens directly into Firefox kiosk
# ==============================================================================
set -e

# ── Config ────────────────────────────────────────────────────────────────────
VM_NAME="alpine-firefox"
DISK="alpine-vm.qcow2"
SEED="seed.iso"
MEMORY=2048
CPUS=2
USERNAME="max"
USER_PASS="maxpassword"
ROOT_PASS="rootpassword"
KIOSK_URL="https://example.com"
RESOLUTION="1280x800"
# ─────────────────────────────────────────────────────────────────────────────

# ── Dependency check ──────────────────────────────────────────────────────────
echo "Checking dependencies..."
for cmd in qemu-system-x86_64 qemu-img cloud-localds wget; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install with:"
        echo "  sudo apt install qemu-system-x86 qemu-utils cloud-image-utils wget"
        exit 1
    fi
done

# ── 1. Alpine cloud image ─────────────────────────────────────────────────────
IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2"
if [ ! -f base.qcow2 ]; then
    echo "Downloading Alpine cloud image..."
    wget --progress=bar:force -O base.qcow2 "$IMAGE_URL"
fi

if [ ! -f "$DISK" ]; then
    echo "Creating VM disk overlay..."
    qemu-img create -f qcow2 -b base.qcow2 -F qcow2 "$DISK" 10G
fi

# ── 2. SSH key ────────────────────────────────────────────────────────────────
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating SSH keypair..."
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi
PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)

# ── 3. Cloud-init user-data ───────────────────────────────────────────────────
# Outer heredoc is UNQUOTED so shell variables ($USERNAME, $PUB_KEY, etc.) expand.
# Inner heredocs use 'QUOTED' markers so their content is written literally.
cat > user-data << EOF
#cloud-config

hostname: alpine-vm
fqdn: alpine-vm.local
manage_etc_hosts: true

users:
  - default
  - name: root
    lock_passwd: false
  - name: ${USERNAME}
    groups: wheel,video,audio,input
    shell: /bin/ash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${PUB_KEY}

ssh_pwauth: true
disable_root: false

chpasswd:
  list: |
    root:${ROOT_PASS}
    ${USERNAME}:${USER_PASS}
  expire: false

package_update: true
package_upgrade: true

packages:
  # X11 server
  - xorg-server
  - xorg-server-common
  - xinit
  - xf86-input-libinput
  - xf86-video-modesetting
  # Mesa / OpenGL — required for virtio-gpu DRM
  - mesa-dri-gallium
  - mesa-gl
  - mesa-egl
  - libdrm
  # Window manager + browser
  - openbox
  - firefox
  - font-dejavu
  # D-Bus (needed by Firefox and Openbox)
  - dbus
  - dbus-openrc
  - dbus-x11
  # Device manager (eudev = Alpine's udev)
  - eudev
  - eudev-openrc
  # Seat / session management
  - elogind
  - elogind-openrc
  # Utilities
  - sudo
  - util-linux
  - setxkbmap
  - xrandr

runcmd:
  # ── Load GPU kernel modules ──────────────────────────────────────────────
  - |
    for mod in virtio_gpu drm drm_kms_helper; do
      echo "\$mod" >> /etc/modules
      modprobe "\$mod" 2>/dev/null || true
    done

  # ── Start device + session services ─────────────────────────────────────
  - rc-update add eudev sysinit
  - rc-service eudev start || true
  - rc-update add dbus default
  - rc-service dbus start || true
  - rc-update add elogind default
  - rc-service elogind start || true

  # ── udev: make /dev/dri/card0 accessible to the video group ─────────────
  - |
    cat > /etc/udev/rules.d/99-drm.rules << 'EOR'
    SUBSYSTEM=="drm", GROUP="video", MODE="0660"
    SUBSYSTEM=="input", GROUP="input", MODE="0660"
    EOR
  - udevadm control --reload-rules 2>/dev/null || true
  - udevadm trigger 2>/dev/null || true

  # ── Xorg config for virtio-gpu via modesetting driver ───────────────────
  - mkdir -p /etc/X11/xorg.conf.d
  - |
    cat > /etc/X11/xorg.conf.d/10-virtio-gpu.conf << 'EOX'
    Section "ServerFlags"
        Option "AutoAddDevices"    "true"
        Option "AutoEnableDevices" "true"
        Option "AllowEmptyInput"   "true"
    EndSection

    Section "Device"
        Identifier "VirtIO GPU"
        Driver     "modesetting"
        Option     "AccelMethod" "none"
    EndSection

    Section "Screen"
        Identifier "Screen0"
        Device     "VirtIO GPU"
        DefaultDepth 24
        SubSection "Display"
            Depth  24
            Modes  "${RESOLUTION}" "1024x768" "800x600"
        EndSubSection
    EndSection
    EOX

  # ── Allow non-root Xorg startup ──────────────────────────────────────────
  - |
    cat > /etc/X11/Xwrapper.config << 'EOW'
    allowed_users=anybody
    needs_root_rights=no
    EOW

  # ── Prepare user home dirs ───────────────────────────────────────────────
  - mkdir -p /home/${USERNAME}/.config/openbox
  - mkdir -p /home/${USERNAME}/.local/share

  # ── Openbox autostart ────────────────────────────────────────────────────
  # Openbox runs this script on session start.
  # Firefox is wrapped in a watchdog loop so it restarts if it crashes.
  - |
    cat > /home/${USERNAME}/.config/openbox/autostart << 'EOA'
    # Disable screen blanking and power management
    xset -dpms &
    xset s off &
    xset s noblank &

    # Set display resolution (virtio-gpu output is named Virtual-1)
    xrandr --output Virtual-1 --mode ${RESOLUTION} 2>/dev/null \
        || xrandr --output Virtual-1 --mode 1024x768 2>/dev/null \
        || true &

    # Kiosk watchdog: restart Firefox automatically if it exits
    (
      while true; do
        firefox --kiosk ${KIOSK_URL} \
                --no-remote \
                --disable-pinch \
                2>/tmp/firefox.log
        sleep 2
      done
    ) &
    EOA
  - chmod +x /home/${USERNAME}/.config/openbox/autostart

  # ── .xinitrc: launch dbus session then openbox ───────────────────────────
  - |
    cat > /home/${USERNAME}/.xinitrc << 'EOX'
    #!/bin/sh
    # Start a per-session dbus instance
    eval \$(dbus-launch --sh-syntax --exit-with-session)
    export DBUS_SESSION_BUS_ADDRESS
    # Hand off to openbox (reads ~/.config/openbox/autostart)
    exec openbox-session
    EOX
  - chmod +x /home/${USERNAME}/.xinitrc

  # ── .profile: trigger startx automatically when on tty1 ─────────────────
  # ash reads .profile for every login shell (which agetty --autologin creates).
  - |
    cat > /home/${USERNAME}/.profile << 'EOP'
    #!/bin/sh
    if [ "\$(tty)" = "/dev/tty1" ] && [ -z "\${DISPLAY}" ]; then
        # Xorg log at /tmp/xorg-startup.log — check it if GUI does not appear
        exec startx "\${HOME}/.xinitrc" -- :0 vt1 -nolisten tcp \
            > /tmp/xorg-startup.log 2>&1
    fi
    EOP
  - chmod +x /home/${USERNAME}/.profile

  # ── Autologin on tty1 via agetty (part of util-linux) ───────────────────
  # Replaces the default getty with one that auto-logs in $USERNAME.
  # --autologin skips the password prompt entirely.
  - sed -Ei "s|^tty1.*|tty1::respawn:/sbin/agetty --autologin ${USERNAME} --noclear tty1 linux|" /etc/inittab

  # ── Fix file ownership ───────────────────────────────────────────────────
  - chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

  # ── Debug tips (SSH in after first boot if GUI fails) ───────────────────
  # cat /tmp/xorg-startup.log     — Xorg errors
  # cat /tmp/firefox.log          — Firefox errors
  # ls -la /dev/dri/              — check /dev/dri/card0 exists
  # groups ${USERNAME}            — confirm video group

power_state:
  mode: reboot
  delay: now
  message: "cloud-init done — rebooting to GUI"
EOF

# ── 4. Meta-data ──────────────────────────────────────────────────────────────
cat > meta-data << EOF
instance-id: iid-${VM_NAME}
local-hostname: ${VM_NAME}
EOF

# ── 5. Seed ISO ───────────────────────────────────────────────────────────────
echo "Building cloud-init seed ISO..."
cloud-localds "$SEED" user-data meta-data

# ── 6. Launch QEMU ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  VM:        $VM_NAME"
echo "  Display:   QEMU GTK window (${RESOLUTION})"
echo "  SSH:       ssh -p 2222 ${USERNAME}@localhost"
echo ""
echo "  First boot  → cloud-init installs packages (~2-3 min)"
echo "                VM reboots automatically when done."
echo "  Second boot → QEMU window shows Firefox in kiosk mode."
echo ""
echo "  If GUI fails, SSH in and run:"
echo "    cat /tmp/xorg-startup.log"
echo "    ls -la /dev/dri/"
echo "════════════════════════════════════════════════════"
echo ""

exec qemu-system-x86_64 \
    -name    "$VM_NAME" \
    -m       "$MEMORY" \
    -smp     "$CPUS" \
    -cpu     host \
    -enable-kvm \
    \
    -drive   file="$DISK",if=virtio,format=qcow2 \
    -drive   file="$SEED",if=virtio,format=raw,readonly=on \
    \
    -netdev  user,id=net0,hostfwd=tcp::2222-:22 \
    -device  virtio-net-pci,netdev=net0 \
    \
    -vga     none \
    -device  virtio-gpu-pci,xres=1280,yres=800 \
    -display gtk,gl=on \
    \
    -device  virtio-keyboard-pci \
    -device  virtio-mouse-pci \
    \
    -boot    c
