#!/usr/bin/env bash
# =============================================================================
#  kiosk-vm.sh — Firefox-only QEMU kiosk VM
#  Alpine Linux + cloud-init + Openbox (or Wayland/Cage)
#
#  Usage:
#    ./kiosk-vm.sh [OPTIONS]
#
#  Options:
#    -u URL        Homepage URL           (default: https://example.com)
#    -m MB         RAM in megabytes       (default: 2048)
#    -c CORES      vCPU count             (default: 2)
#    -s GB         Disk size in GB        (default: 5)
#    -d MODE       Display: sdl|vnc|gtk   (default: sdl)
#    -w            Use Wayland+Cage instead of Openbox
#    -r            Force re-provision (rebuild seed ISO + fresh disk)
#    -n            Dry-run (print commands, don't execute)
#    -h            Show this help
#
#  Examples:
#    ./kiosk-vm.sh
#    ./kiosk-vm.sh -u https://www.google.com -m 4096 -c 4
#    ./kiosk-vm.sh -d vnc
#    ./kiosk-vm.sh -w           # Wayland + Cage variant
#    ./kiosk-vm.sh -r           # wipe and re-provision
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
KIOSK_URL="https://example.com"
VM_RAM=2048
VM_CPUS=2
DISK_SIZE_GB=5
DISPLAY_MODE="sdl"
USE_WAYLAND=false
FORCE_REPROVISION=false
DRY_RUN=false

WORKDIR="$(pwd)/kiosk-vm"
DISK_IMG="${WORKDIR}/alpine-kiosk.qcow2"
SEED_ISO="${WORKDIR}/seed.iso"
SEED_DIR="${WORKDIR}/seed"

ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.0"
ALPINE_ARCH="x86_64"
ALPINE_IMG_NAME="nocloud_alpine-${ALPINE_RELEASE}-${ALPINE_ARCH}-bios-cloudinit-r0.qcow2"
ALPINE_IMG_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/cloud/${ALPINE_IMG_NAME}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ${RESET}"; }
run()     { if $DRY_RUN; then echo -e "${YELLOW}[dry-run]${RESET} $*"; else eval "$@"; fi; }

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   Firefox Kiosk VM — Alpine + QEMU       ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ── Help ─────────────────────────────────────────────────────────────────────
print_help() {
  sed -n '/^#  Usage:/,/^# ===/p' "$0" | sed 's/^#  \?/  /' | head -n -1
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while getopts ":u:m:c:s:d:wrnhH" opt; do
  case $opt in
    u) KIOSK_URL="$OPTARG" ;;
    m) VM_RAM="$OPTARG" ;;
    c) VM_CPUS="$OPTARG" ;;
    s) DISK_SIZE_GB="$OPTARG" ;;
    d) DISPLAY_MODE="$OPTARG" ;;
    w) USE_WAYLAND=true ;;
    r) FORCE_REPROVISION=true ;;
    n) DRY_RUN=true ;;
    h|H) print_help ;;
    :) error "Option -$OPTARG requires an argument." ;;
    \?) error "Unknown option: -$OPTARG" ;;
  esac
done

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  step "Checking dependencies"

  local missing=()

  command -v qemu-system-x86_64 &>/dev/null || missing+=("qemu-system-x86_64")
  command -v qemu-img            &>/dev/null || missing+=("qemu-img")

  # wget or curl for download
  if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    missing+=("wget or curl")
  fi

  # ISO tool: genisoimage or mkisofs or xorriso
  if ! command -v genisoimage &>/dev/null && \
     ! command -v mkisofs     &>/dev/null && \
     ! command -v xorriso     &>/dev/null; then
    missing+=("genisoimage (or mkisofs or xorriso)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}\n\n  Ubuntu/Debian: sudo apt install qemu-system-x86 qemu-utils genisoimage\n  Arch:          sudo pacman -S qemu genisoimage\n  macOS:         brew install qemu xorriso"
  fi

  # Detect ISO builder
  if command -v genisoimage &>/dev/null; then
    ISO_CMD="genisoimage"
  elif command -v mkisofs &>/dev/null; then
    ISO_CMD="mkisofs"
  else
    ISO_CMD="xorriso"
  fi

  # KVM availability
  KVM_FLAG=""
  if [[ -r /dev/kvm ]]; then
    KVM_FLAG="-enable-kvm -cpu host"
    success "KVM available — hardware acceleration enabled"
  else
    warn "KVM not available — VM will run in TCG (software) mode, expect slower performance"
  fi

  success "All dependencies found (ISO builder: ${ISO_CMD})"
}

# ── Download Alpine cloud image ───────────────────────────────────────────────
download_image() {
  step "Alpine cloud image"

  mkdir -p "${WORKDIR}"

  if [[ -f "${DISK_IMG}" ]] && ! $FORCE_REPROVISION; then
    success "Disk image already exists: ${DISK_IMG}"
    info "Use -r to force re-download and re-provision"
    return
  fi

  local raw_img="${WORKDIR}/${ALPINE_IMG_NAME}"

  if [[ ! -f "${raw_img}" ]]; then
    info "Downloading Alpine ${ALPINE_RELEASE} cloud image…"
    if command -v wget &>/dev/null; then
      run wget -q --show-progress -O "${raw_img}" "${ALPINE_IMG_URL}"
    else
      run curl -L --progress-bar -o "${raw_img}" "${ALPINE_IMG_URL}"
    fi
    success "Downloaded: ${raw_img}"
  else
    info "Raw image already downloaded, skipping download"
  fi

  info "Copying to working disk image…"
  run cp "${raw_img}" "${DISK_IMG}"

  info "Resizing disk to ${DISK_SIZE_GB}G…"
  run qemu-img resize "${DISK_IMG}" "${DISK_SIZE_GB}G"
  success "Disk ready: ${DISK_IMG} (${DISK_SIZE_GB} GB)"
}

# ── Write cloud-init files ────────────────────────────────────────────────────
write_cloud_init() {
  step "Writing cloud-init files"

  mkdir -p "${SEED_DIR}"

  # ── meta-data ──────────────────────────────────────────────────────────────
  cat > "${SEED_DIR}/meta-data" <<'METADATA'
instance-id: firefox-kiosk-01
local-hostname: kiosk
METADATA

  # ── user-data: Openbox path ────────────────────────────────────────────────
  if ! $USE_WAYLAND; then
    info "Writing user-data (Openbox / Xorg)"
    cat > "${SEED_DIR}/user-data" <<USERDATA
#cloud-config

# ── User ──────────────────────────────────────────────────────────────────────
users:
  - name: kiosk
    gecos: Kiosk User
    groups:
      - audio
      - video
      - input
      - seat       # needed by elogind for device access
    shell: /bin/sh
    lock_passwd: true

# ── Packages ──────────────────────────────────────────────────────────────────
packages:
  - xorg-server
  - xf86-video-fbdev
  - xf86-video-vesa
  - xf86-input-libinput
  - openbox
  - firefox
  - ttf-freefont
  - dbus
  - elogind       # seat + device manager — lets non-root user run Xorg
  - setxkbmap
  - xdotool
  - xrandr
  - unclutter

package_update: true

# ── Files ─────────────────────────────────────────────────────────────────────
write_files:

  - path: /home/kiosk/.xinitrc
    owner: kiosk:kiosk
    permissions: '0755'
    content: |
      #!/bin/sh
      # Redirect everything so failures are visible in /tmp/xorg.log
      exec >> /tmp/xorg.log 2>&1
      echo "[xinitrc] started at \$(date)"
      eval \$(dbus-launch --sh-syntax)
      setxkbmap us
      xset s off
      xset s noblank
      xset -dpms
      unclutter -idle 0 &
      exec openbox-session

  - path: /home/kiosk/.config/openbox/autostart
    owner: kiosk:kiosk
    permissions: '0755'
    content: |
      #!/bin/sh
      sleep 1
      exec firefox --kiosk --no-remote "${KIOSK_URL}" &

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
          <keybind key="A-F4"><action name="Close"/></keybind>
        </keyboard>
        <mouse><dragThreshold>8</dragThreshold><doubleClickTime>200</doubleClickTime></mouse>
        <applications>
          <application class="Firefox">
            <maximized>yes</maximized>
            <decor>no</decor>
            <fullscreen>yes</fullscreen>
          </application>
        </applications>
      </openbox_config>

  - path: /home/kiosk/.profile
    owner: kiosk:kiosk
    permissions: '0644'
    content: |
      # Use case-match so it works whether tty prints "/dev/tty1" or "tty1"
      case "\$(tty)" in
        *tty1)
          [ -z "\$DISPLAY" ] && exec startx -- -nocursor >> /tmp/xorg.log 2>&1
          ;;
      esac

  - path: /etc/X11/xorg.conf.d/10-fbdev.conf
    permissions: '0644'
    content: |
      Section "Device"
        Identifier "Framebuffer"
        Driver     "fbdev"
      EndSection

# ── Commands ──────────────────────────────────────────────────────────────────
runcmd:
  - chown -R kiosk:kiosk /home/kiosk
  # elogind: seat & device manager required for non-root Xorg
  - rc-update add elogind default
  - rc-service elogind start
  - rc-update add dbus default
  - rc-service dbus start
  # Write autologin helper in runcmd (guaranteed on-disk before inittab is touched)
  - printf '#!/bin/sh\nexec /bin/login -f kiosk\n' > /usr/local/bin/autologin
  - chmod 755 /usr/local/bin/autologin
  - sed -i 's|tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/getty -n -l /usr/local/bin/autologin 38400 tty1 linux|' /etc/inittab
  - kill -HUP 1

# ── Auto-reboot after provisioning ────────────────────────────────────────────
# Without this the VM sits at a text console after cloud-init finishes.
power_state:
  mode: reboot
  delay: now
  message: "cloud-init done — rebooting into kiosk mode"

final_message: |
  ✓ Openbox kiosk setup complete — rebooting now.
USERDATA

  # ── user-data: Wayland + Cage path ────────────────────────────────────────
  else
    info "Writing user-data (Wayland + Cage)"
    cat > "${SEED_DIR}/user-data" <<USERDATA
#cloud-config

# ── User ──────────────────────────────────────────────────────────────────────
users:
  - name: kiosk
    gecos: Kiosk User
    groups:
      - audio
      - video
      - input
      - seat
    shell: /bin/sh
    lock_passwd: true

# ── Packages ──────────────────────────────────────────────────────────────────
packages:
  - cage
  - seatd
  - firefox
  - ttf-freefont
  - dbus

package_update: true

# ── Files ─────────────────────────────────────────────────────────────────────
write_files:

  - path: /home/kiosk/.profile
    owner: kiosk:kiosk
    permissions: '0644'
    content: |
      case "\$(tty)" in
        *tty1)
          if [ -z "\$WAYLAND_DISPLAY" ]; then
            export XDG_RUNTIME_DIR=/run/user/\$(id -u)
            mkdir -p "\$XDG_RUNTIME_DIR"
            chmod 0700 "\$XDG_RUNTIME_DIR"
            exec cage -- firefox --kiosk "${KIOSK_URL}" >> /tmp/cage.log 2>&1
          fi
          ;;
      esac

# ── Commands ──────────────────────────────────────────────────────────────────
runcmd:
  - chown -R kiosk:kiosk /home/kiosk
  - rc-update add seatd default
  - rc-service seatd start
  - adduser kiosk seat
  - rc-update add dbus default
  - rc-service dbus start
  # Write autologin helper in runcmd (guaranteed on-disk before inittab is touched)
  - printf '#!/bin/sh\nexec /bin/login -f kiosk\n' > /usr/local/bin/autologin
  - chmod 755 /usr/local/bin/autologin
  - sed -i 's|tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/getty -n -l /usr/local/bin/autologin 38400 tty1 linux|' /etc/inittab
  - kill -HUP 1

# ── Auto-reboot after provisioning ────────────────────────────────────────────
power_state:
  mode: reboot
  delay: now
  message: "cloud-init done — rebooting into kiosk mode"

final_message: |
  ✓ Wayland/Cage kiosk setup complete — rebooting now.
USERDATA
  fi

  success "cloud-init files written to ${SEED_DIR}/"
}

# ── Build seed ISO ────────────────────────────────────────────────────────────
build_seed_iso() {
  step "Building cloud-init seed ISO"

  if [[ -f "${SEED_ISO}" ]] && ! $FORCE_REPROVISION; then
    success "Seed ISO already exists: ${SEED_ISO}"
    return
  fi

  if [[ "${ISO_CMD}" == "xorriso" ]]; then
    run xorriso -as mkisofs \
      -output "${SEED_ISO}" \
      -volid cidata \
      -joliet -rock \
      "${SEED_DIR}/user-data" \
      "${SEED_DIR}/meta-data"
  else
    run "${ISO_CMD}" \
      -output "${SEED_ISO}" \
      -volid cidata \
      -joliet -rock \
      "${SEED_DIR}/user-data" \
      "${SEED_DIR}/meta-data"
  fi

  success "Seed ISO built: ${SEED_ISO}"
}

# ── Build QEMU command ────────────────────────────────────────────────────────
build_qemu_cmd() {
  local display_args=""

  case "${DISPLAY_MODE}" in
    sdl)
      display_args="-vga virtio -display sdl,gl=off"
      ;;
    gtk)
      display_args="-vga virtio -display gtk,gl=off"
      ;;
    vnc)
      display_args="-vga std -display vnc=127.0.0.1:0"
      warn "VNC mode: connect with  vncviewer 127.0.0.1:5900"
      ;;
    *)
      error "Unknown display mode '${DISPLAY_MODE}'. Valid: sdl, gtk, vnc"
      ;;
  esac

  QEMU_CMD="qemu-system-x86_64 \
    ${KVM_FLAG} \
    -name firefox-kiosk \
    -smp ${VM_CPUS} \
    -m ${VM_RAM} \
    -drive file=${DISK_IMG},format=qcow2,if=virtio \
    -drive file=${SEED_ISO},format=raw,if=virtio,readonly=on \
    ${display_args} \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -nic user,model=virtio-net-pci \
    -serial mon:stdio \
    -boot order=c"
}

# ── Print summary ─────────────────────────────────────────────────────────────
print_summary() {
  local wm="Openbox (Xorg)"
  $USE_WAYLAND && wm="Cage (Wayland)"

  echo
  echo -e "${BOLD}  Configuration summary${RESET}"
  echo    "  ──────────────────────────────────────"
  echo -e "  URL         ${CYAN}${KIOSK_URL}${RESET}"
  echo -e "  WM          ${CYAN}${wm}${RESET}"
  echo -e "  RAM         ${CYAN}${VM_RAM} MB${RESET}"
  echo -e "  CPUs        ${CYAN}${VM_CPUS}${RESET}"
  echo -e "  Disk        ${CYAN}${DISK_SIZE_GB} GB${RESET}"
  echo -e "  Display     ${CYAN}${DISPLAY_MODE}${RESET}"
  echo -e "  Work dir    ${CYAN}${WORKDIR}${RESET}"
  echo    "  ──────────────────────────────────────"
  echo
  echo -e "${YELLOW}  ⚑  First boot:${RESET} cloud-init will install packages (~2-5 min)."
  echo    "     After cloud-init finishes, the VM will reboot automatically"
  echo    "     and Firefox will launch on the next boot."
  echo
}

# ── Launch QEMU ───────────────────────────────────────────────────────────────
launch_vm() {
  step "Launching QEMU"
  info "Command:"
  echo -e "  ${YELLOW}${QEMU_CMD}${RESET}\n"

  if $DRY_RUN; then
    warn "Dry-run mode — QEMU not started"
    return
  fi

  # shellcheck disable=SC2086
  eval ${QEMU_CMD}
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  print_banner
  print_summary

  check_deps
  download_image
  write_cloud_init
  build_seed_iso
  build_qemu_cmd

  echo
  info "Everything is ready. Starting the VM…"
  echo -e "  ${YELLOW}Tip:${RESET} Press Ctrl-A then X inside the serial console to quit QEMU."
  echo -e "  ${YELLOW}Tip:${RESET} To run without the seed ISO after first boot, delete ${SEED_ISO}"
  echo -e "       and re-run — the script will skip re-provisioning automatically.\n"

  launch_vm
}

main "$@"
