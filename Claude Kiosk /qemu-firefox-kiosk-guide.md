# QEMU Firefox-Only Kiosk VM
## Alpine Linux + cloud-init + Openbox

A complete guide to building a minimal GUI VM that boots straight into Firefox —
using Alpine Cloud as the base OS, cloud-init for zero-touch provisioning,
and Openbox as the window manager.

---

## Table of Contents

1. [Overview & Architecture](#overview)
2. [Prerequisites](#prerequisites)
3. [Download Alpine Cloud Image](#download)
4. [Build the cloud-init Seed ISO](#seed-iso)
5. [cloud-init Files](#cloud-init-files)
   - [meta-data](#meta-data)
   - [user-data (Openbox — primary)](#user-data-openbox)
   - [user-data (Wayland + Cage — alternative)](#user-data-cage)
6. [QEMU Launch Command](#qemu-launch)
7. [Display Options](#display-options)
8. [Persistence & Disk Resize](#persistence)
9. [Troubleshooting](#troubleshooting)

---

## 1. Overview & Architecture {#overview}

```
┌─────────────────────────────────────────────────┐
│  QEMU VM                                        │
│                                                 │
│  Alpine Linux (cloud image)                     │
│  └─ cloud-init (first boot)                     │
│      ├─ creates "kiosk" user                    │
│      ├─ installs Xorg + Openbox + Firefox       │
│      ├─ configures auto-login on tty1           │
│      └─ startx → openbox → firefox --kiosk      │
└─────────────────────────────────────────────────┘
         │ display
    ┌────┴────┐
    │ SDL/VNC │  ← host sees the VM's screen
    └─────────┘
```

**Why Openbox?**  Minimal RAM footprint (~5 MB), no compositor overhead,
starts in under a second, and Firefox runs natively under Xorg with full
hardware-accelerated rendering via the virtio-gpu or VGA driver.

**Why not a full DE?**  GNOME/KDE pull in hundreds of MB of deps. For a
single-app kiosk, Openbox is the right tool.

---

## 2. Prerequisites {#prerequisites}

On your **host machine** you need:

| Tool | Purpose | Install |
|------|---------|---------|
| `qemu-system-x86_64` | Run the VM | `apt install qemu-system-x86` / `brew install qemu` |
| `genisoimage` or `mkisofs` | Build seed ISO | `apt install genisoimage` |
| `qemu-img` | Resize disk image | included with QEMU |

---

## 3. Download Alpine Cloud Image {#download}

Alpine publishes ready-to-use cloud images (NoCloud compatible).

```bash
# Get the latest Alpine 3.21 cloud image (x86_64)
wget https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.0-x86_64-bios-cloudinit-r0.qcow2

# Rename for convenience
mv nocloud_alpine-*.qcow2 alpine-kiosk.qcow2
```

> **Note:** The `nocloud` variant has cloud-init pre-installed and waits for
> a NoCloud datasource on first boot. Do NOT use the standard `alpine-virt`
> ISO for this workflow — cloud images are different.

Check for latest releases at:  
`https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/`

---

## 4. Build the cloud-init Seed ISO {#seed-iso}

cloud-init reads its config from a small ISO labelled `cidata`. You create
it once on the host and attach it to QEMU.

```bash
mkdir -p seed
# Place your meta-data and user-data files in seed/ (see next section)
# Then build the ISO:

genisoimage \
  -output seed.iso \
  -volid cidata \
  -joliet \
  -rock \
  seed/user-data \
  seed/meta-data

# Verify
file seed.iso   # should say ISO 9660
```

---

## 5. cloud-init Files {#cloud-init-files}

### 5a. meta-data {#meta-data}

```yaml
# seed/meta-data
instance-id: firefox-kiosk-01
local-hostname: kiosk
```

---

### 5b. user-data — Openbox (primary) {#user-data-openbox}

Save as `seed/user-data`:

```yaml
#cloud-config

# ─── User ───────────────────────────────────────────────────────────────────
users:
  - name: kiosk
    gecos: Kiosk User
    groups:
      - audio
      - video
      - input
    shell: /bin/sh
    lock_passwd: true          # no password login — only auto-login

# ─── Packages ────────────────────────────────────────────────────────────────
# cloud-init on Alpine uses 'apk', so list packages directly.
packages:
  - xorg-server
  - xf86-video-fbdev           # works well with QEMU's VGA/virtio
  - xf86-video-vesa
  - xf86-input-libinput
  - openbox
  - firefox
  - ttf-freefont               # fonts — Firefox needs them
  - dbus
  - setxkbmap
  - xdotool                    # optional: useful for scripted kiosk control
  - xrandr                     # optional: set resolution at startup

package_update: true

# ─── Files ───────────────────────────────────────────────────────────────────
write_files:

  # 1. xinit entry point — starts openbox
  - path: /home/kiosk/.xinitrc
    owner: kiosk:kiosk
    permissions: '0755'
    content: |
      #!/bin/sh
      # Start dbus session
      eval $(dbus-launch --sh-syntax)
      # Set keyboard layout (adjust as needed)
      setxkbmap us
      # Disable screen blanking and power saving
      xset s off
      xset s noblank
      xset -dpms
      # Launch Openbox
      exec openbox-session

  # 2. Openbox autostart — runs Firefox after WM is ready
  - path: /home/kiosk/.config/openbox/autostart
    owner: kiosk:kiosk
    permissions: '0755'
    content: |
      #!/bin/sh
      # Brief pause to let Openbox fully initialize
      sleep 1
      # Launch Firefox in kiosk mode (no URL bar, no chrome)
      exec firefox --kiosk --no-remote "https://example.com" &

  # 3. Openbox rc.xml — minimal config (no right-click menu, no taskbar)
  - path: /home/kiosk/.config/openbox/rc.xml
    owner: kiosk:kiosk
    permissions: '0644'
    content: |
      <?xml version="1.0" encoding="UTF-8"?>
      <openbox_config xmlns="http://openbox.org/3.4/rc">
        <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
        <focus><focusNew>yes</focusNew><followMouse>no</followMouse><focusDelay>200</focusDelay></focus>
        <placement><policy>Smart</policy></placement>
        <theme><name>Clearlooks</name><titleLayout>NLIMC</titleLayout></theme>
        <desktops><number>1</number><names><name>Kiosk</name></names></desktops>
        <keyboard>
          <!-- Alt+F4 closes window — remove if full lockdown needed -->
          <keybind key="A-F4"><action name="Close"/></keybind>
        </keyboard>
        <mouse>
          <dragThreshold>8</dragThreshold>
          <doubleClickTime>200</doubleClickTime>
        </mouse>
        <applications>
          <!-- Make Firefox always maximized and without decorations -->
          <application class="Firefox">
            <maximized>yes</maximized>
            <decor>no</decor>
            <fullscreen>yes</fullscreen>
          </application>
        </applications>
      </openbox_config>

  # 4. Shell profile — auto-starts X when logging in on tty1
  - path: /home/kiosk/.profile
    owner: kiosk:kiosk
    permissions: '0644'
    content: |
      # Auto-start X on the first virtual terminal only
      if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
        exec startx -- -nocursor 2>/tmp/xorg.log
      fi

  # 5. Auto-login helper — called by getty on tty1
  - path: /usr/local/bin/autologin
    permissions: '0755'
    content: |
      #!/bin/sh
      exec /bin/login -f kiosk

# ─── Commands (run once on first boot) ───────────────────────────────────────
runcmd:

  # Fix ownership of kiosk home (cloud-init creates files as root)
  - chown -R kiosk:kiosk /home/kiosk

  # Configure getty on tty1 for automatic login
  # Alpine uses BusyBox inittab
  - sed -i 's|tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/getty -n -l /usr/local/bin/autologin 38400 tty1 linux|' /etc/inittab

  # Enable and start dbus
  - rc-update add dbus default
  - rc-service dbus start

  # Apply inittab changes (sends SIGHUP to init)
  - kill -HUP 1

# ─── Final message ────────────────────────────────────────────────────────────
final_message: |
  ✓ Kiosk setup complete. Reboot the VM to start the Firefox kiosk session.
```

---

### 5c. user-data — Wayland + Cage (alternative) {#user-data-cage}

If you prefer a Wayland compositor, replace the `packages` and `write_files`
sections with the following. Everything else (`users`, `meta-data`, runcmd
for autologin) stays the same.

```yaml
#cloud-config
# ── Wayland + Cage variant ──

users:
  - name: kiosk
    groups: [audio, video, input, seat]
    shell: /bin/sh
    lock_passwd: true

packages:
  - cage                  # single-window Wayland compositor
  - seatd                 # seat management daemon (required by cage)
  - firefox
  - ttf-freefont
  - dbus

package_update: true

write_files:

  # Profile: auto-start Cage after login
  - path: /home/kiosk/.profile
    owner: kiosk:kiosk
    permissions: '0644'
    content: |
      if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
        export XDG_RUNTIME_DIR=/run/user/$(id -u)
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 0700 "$XDG_RUNTIME_DIR"
        exec cage -- firefox --kiosk "https://example.com" 2>/tmp/cage.log
      fi

  - path: /usr/local/bin/autologin
    permissions: '0755'
    content: |
      #!/bin/sh
      exec /bin/login -f kiosk

runcmd:
  - chown -R kiosk:kiosk /home/kiosk
  - rc-update add seatd default
  - rc-service seatd start
  - adduser kiosk seat
  - sed -i 's|tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/getty -n -l /usr/local/bin/autologin 38400 tty1 linux|' /etc/inittab
  - rc-update add dbus default
  - rc-service dbus start
  - kill -HUP 1
```

> **Cage note:** Cage is a "cage for a single application" — it locks the
> compositor to exactly one Wayland client (Firefox). There is no taskbar,
> no alt-tab, nothing else. Perfect for kiosks but harder to debug.

---

## 6. QEMU Launch Command {#qemu-launch}

```bash
qemu-system-x86_64 \
  -name "firefox-kiosk" \
  \
  # ── CPU & Memory ──────────────────────────────────
  -enable-kvm \                    # remove on macOS/Windows or if KVM unavailable
  -cpu host \
  -smp 2 \
  -m 2048 \
  \
  # ── Disks ─────────────────────────────────────────
  -drive file=alpine-kiosk.qcow2,format=qcow2,if=virtio \
  -drive file=seed.iso,format=raw,if=virtio,readonly=on \
  \
  # ── Display ───────────────────────────────────────
  -vga virtio \                    # virtio-gpu: best performance
  -display sdl,gl=off \            # SDL window on host (see alternatives below)
  \
  # ── Input ─────────────────────────────────────────
  -device virtio-keyboard-pci \
  -device virtio-tablet-pci \      # tablet = absolute mouse coords, no grab needed
  \
  # ── Network ───────────────────────────────────────
  -nic user,model=virtio-net-pci \
  \
  # ── Boot ──────────────────────────────────────────
  -boot order=c \
  -serial mon:stdio                # access VM console via terminal
```

**One-liner (copy-paste ready):**

```bash
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
  -drive file=alpine-kiosk.qcow2,format=qcow2,if=virtio \
  -drive file=seed.iso,format=raw,if=virtio,readonly=on \
  -vga virtio -display sdl,gl=off \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -nic user,model=virtio-net-pci \
  -serial mon:stdio
```

---

## 7. Display Options {#display-options}

Replace the `-display` flag to change how you see the VM:

| Mode | Flag | When to use |
|------|------|-------------|
| **SDL** (default) | `-display sdl,gl=off` | Local desktop, simplest setup |
| **GTK window** | `-display gtk,gl=off` | GTK-based host desktops |
| **VNC** | `-display vnc=127.0.0.1:0` | Headless / remote access via `vncviewer :0` |
| **SPICE** | `-spice port=5900,disable-ticketing=on` + `-display spice-app` | Best remote quality, supports clipboard/audio |
| **No display** | `-display none` | Fully headless (useful with VNC) |

**For VNC (headless server example):**

```bash
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
  -drive file=alpine-kiosk.qcow2,format=qcow2,if=virtio \
  -drive file=seed.iso,format=raw,if=virtio,readonly=on \
  -vga std \
  -display vnc=127.0.0.1:0 \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -nic user,model=virtio-net-pci \
  -daemonize

# Connect from host:
vncviewer 127.0.0.1:5900
```

---

## 8. Persistence & Disk Resize {#persistence}

The Alpine cloud image defaults to ~300 MB. Firefox needs more space.

```bash
# Resize the qcow2 image BEFORE first boot
qemu-img resize alpine-kiosk.qcow2 +4G

# cloud-init will automatically grow the root partition on first boot
# (the alpine cloud image includes growpart support)
```

**To save VM state between sessions**, just keep `alpine-kiosk.qcow2` — it
persists everything. The seed ISO is only used on the first boot (cloud-init
marks completion in `/var/lib/cloud/instance/`). You can detach it afterwards:

```bash
# Run without seed ISO after first boot
qemu-system-x86_64 ... \
  -drive file=alpine-kiosk.qcow2,format=qcow2,if=virtio \
  # (no seed.iso drive)
```

---

## 9. Troubleshooting {#troubleshooting}

### X server won't start

Check the log inside the VM:

```sh
cat /tmp/xorg.log
# or
cat /var/log/Xorg.0.log
```

If you see `no screens found`, add the fbdev fallback config:

```bash
# Inside the VM
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-fbdev.conf <<'EOF'
Section "Device"
  Identifier "Framebuffer"
  Driver     "fbdev"
EndSection
EOF
```

### Auto-login not working

Verify `/etc/inittab` was patched:

```sh
grep tty1 /etc/inittab
# Should read: tty1::respawn:/sbin/getty -n -l /usr/local/bin/autologin 38400 tty1 linux
```

If cloud-init didn't apply changes, run the sed command manually and then:

```sh
kill -HUP 1   # reloads inittab without reboot
```

### Firefox opens but wrong size / not fullscreen

In `~/.config/openbox/rc.xml` the `<application class="Firefox">` block
handles this. Alternatively, add to the `autostart` file:

```sh
sleep 2 && xdotool search --onlyvisible --class firefox windowactivate --sync key --clearmodifiers F11 &
```

### cloud-init didn't run (packages missing)

Check cloud-init status:

```sh
cloud-init status --long
cat /var/log/cloud-init-output.log
```

If cloud-init ran but packages are missing, it may have failed silently.
Manually install with `apk add <package>` and check connectivity with
`ping 1.1.1.1`.

### Mouse cursor visible / unwanted

Pass `-nocursor` to the X server in `.profile`:

```sh
exec startx -- -nocursor
```

Or hide it with `unclutter` (add `unclutter -idle 0 &` to autostart).

---

## Quick Reference: File Checklist

```
project/
├── alpine-kiosk.qcow2       ← downloaded cloud image (resize to +4G)
├── seed.iso                 ← built from seed/
└── seed/
    ├── meta-data            ← instance-id + hostname
    └── user-data            ← #cloud-config (the big file above)
```

**Build order:**

```
1. Download image
2. qemu-img resize alpine-kiosk.qcow2 +4G
3. Write meta-data and user-data into seed/
4. genisoimage -output seed.iso -volid cidata -joliet -rock seed/user-data seed/meta-data
5. qemu-system-x86_64 ... (with seed.iso attached)
6. Wait for first boot to complete (cloud-init runs, packages install, ~2–5 min)
7. Reboot VM → Firefox kiosk session starts automatically
```
