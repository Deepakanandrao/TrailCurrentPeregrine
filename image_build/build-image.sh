#!/usr/bin/env bash
# ============================================================================
# TrailCurrent Peregrine — Golden Image Builder
#
# Builds a minimal, branded OS image for the Radxa Dragon Q6A (QCS6490)
# from the stock Radxa OS GNOME image. The resulting image can be flashed
# to any board via edl-ng and boots directly into the voice assistant.
#
# Runs on the dev machine (x86_64 Linux). Requires root for loop-mount
# and chroot into the ARM64 filesystem (via qemu-user-static).
#
# Usage:
#   sudo ./build-image.sh
#
# Output:
#   output/peregrine-q6a-v1.0.img.xz
#
# Prerequisites (install once):
#   sudo apt install qemu-user-static binfmt-support kpartx xz-utils
# ============================================================================

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────────

IMAGE_VERSION="1.0"
IMAGE_NAME="peregrine-q6a-v${IMAGE_VERSION}"

# Stock Radxa OS R2 image (GNOME, NVMe 512-byte sectors)
STOCK_IMAGE_URL="https://github.com/radxa-build/radxa-dragon-q6a/releases/download/rsdk-r2/radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz"
STOCK_IMAGE_FILE="radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz"

# Piper TTS voice
PIPER_VOICE="en_US-libritts_r-medium"
PIPER_VOICE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/libritts_r/medium"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${SCRIPT_DIR}/.cache"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="/tmp/peregrine-build-$$"
MOUNT_DIR="${WORK_DIR}/rootfs"

# Board paths (inside the image)
ASSISTANT_USER="assistant"
ASSISTANT_HOME="/home/${ASSISTANT_USER}"
VENV_DIR="${ASSISTANT_HOME}/assistant-env"
NPU_MODEL_DIR="${ASSISTANT_HOME}/Llama3.2-1B-1024-v68"
PIPER_DIR="${ASSISTANT_HOME}/piper-voices"
WAKE_MODEL_DIR="${ASSISTANT_HOME}/models"

# ── Colors & logging ───────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}════════════════════════════════════════${NC}"; }

LOOP_DEV=""
MOUNTED=false

# ── Cleanup on exit ────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    set +e
    if $MOUNTED; then
        log "Cleaning up mounts..."
        umount -lf "${MOUNT_DIR}/dev/pts" 2>/dev/null
        umount -lf "${MOUNT_DIR}/dev" 2>/dev/null
        umount -lf "${MOUNT_DIR}/proc" 2>/dev/null
        umount -lf "${MOUNT_DIR}/sys" 2>/dev/null
        umount -lf "${MOUNT_DIR}/run" 2>/dev/null
        umount -lf "${MOUNT_DIR}/boot/efi" 2>/dev/null
        umount -lf "${MOUNT_DIR}" 2>/dev/null
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null
    fi
    if [[ $exit_code -ne 0 ]]; then
        warn "Build failed. Working directory preserved at ${WORK_DIR} for debugging."
    else
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# ── Preflight checks ──────────────────────────────────────────────────────

step "Preflight checks"

[[ $(id -u) -eq 0 ]] || fatal "This script must be run as root (sudo ./build-image.sh)"

for cmd in losetup kpartx qemu-aarch64-static xz wget; do
    command -v "$cmd" &>/dev/null || fatal "Missing required tool: $cmd — install prerequisites first"
done

# Check binfmt support for aarch64
if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 &>/dev/null; then
    # Try to register it
    update-binfmts --enable qemu-aarch64 2>/dev/null || true
    if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 &>/dev/null; then
        fatal "qemu-aarch64 binfmt not registered. Install: apt install qemu-user-static binfmt-support"
    fi
fi

log "All prerequisites satisfied"

# ── Download stock image ───────────────────────────────────────────────────

step "Download stock Radxa OS image"

mkdir -p "${CACHE_DIR}" "${OUTPUT_DIR}" "${WORK_DIR}" "${MOUNT_DIR}"

if [[ -f "${CACHE_DIR}/${STOCK_IMAGE_FILE}" ]]; then
    log "Using cached image: ${CACHE_DIR}/${STOCK_IMAGE_FILE}"
else
    log "Downloading stock image (this may take a while)..."
    wget -q --show-progress -O "${CACHE_DIR}/${STOCK_IMAGE_FILE}" "${STOCK_IMAGE_URL}"
    log "Download complete"
fi

# ── Decompress to working copy ────────────────────────────────────────────

step "Decompress image"

IMG_FILE="${WORK_DIR}/${IMAGE_NAME}.img"
log "Decompressing to ${IMG_FILE}..."
xz -dk "${CACHE_DIR}/${STOCK_IMAGE_FILE}" --stdout > "${IMG_FILE}"
log "Decompressed ($(du -h "${IMG_FILE}" | cut -f1))"

# ── Mount the image ───────────────────────────────────────────────────────

step "Mount image partitions"

LOOP_DEV=$(losetup --find --show --partscan "${IMG_FILE}")
log "Loop device: ${LOOP_DEV}"

# Wait for partition devices to appear
sleep 1

# Radxa OS partition layout: p1=config, p2=EFI, p3=root (ext4)
ROOT_PART="${LOOP_DEV}p3"
EFI_PART="${LOOP_DEV}p2"

if [[ ! -b "$ROOT_PART" ]]; then
    # Some systems use kpartx instead
    kpartx -a "${LOOP_DEV}"
    sleep 1
    MAPPER_NAME=$(basename "${LOOP_DEV}")
    ROOT_PART="/dev/mapper/${MAPPER_NAME}p3"
    EFI_PART="/dev/mapper/${MAPPER_NAME}p2"
fi

[[ -b "$ROOT_PART" ]] || fatal "Root partition not found at ${ROOT_PART}"

# First, expand the root filesystem to fill available space in the image
# (the stock image may have extra space; we'll shrink later)
e2fsck -fy "$ROOT_PART" 2>/dev/null || true
resize2fs "$ROOT_PART" 2>/dev/null || true

mount "$ROOT_PART" "${MOUNT_DIR}"
MOUNTED=true
mkdir -p "${MOUNT_DIR}/boot/efi"
mount "$EFI_PART" "${MOUNT_DIR}/boot/efi" 2>/dev/null || warn "No EFI partition or already mounted"

# Bind-mount host filesystems for chroot
mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"
mount -t proc proc "${MOUNT_DIR}/proc"
mount -t sysfs sysfs "${MOUNT_DIR}/sys"
mount --bind /run "${MOUNT_DIR}/run"

# Copy qemu binary for ARM64 emulation
QEMU_BIN=$(which qemu-aarch64-static)
cp "$QEMU_BIN" "${MOUNT_DIR}/usr/bin/"

log "Image mounted at ${MOUNT_DIR}"

# ── Helper: run a command in the chroot ────────────────────────────────────

run_chroot() {
    chroot "${MOUNT_DIR}" /usr/bin/qemu-aarch64-static /bin/bash -c "$*"
}

# Prevent service startup during chroot (they'd fail under qemu anyway)
cat > "${MOUNT_DIR}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${MOUNT_DIR}/usr/sbin/policy-rc.d"

# ── Set hostname ──────────────────────────────────────────────────────────

step "Set hostname to 'peregrine'"

echo "peregrine" > "${MOUNT_DIR}/etc/hostname"
# Update /etc/hosts
sed -i 's/radxa-dragon-q6a/peregrine/g' "${MOUNT_DIR}/etc/hosts"
# Ensure localhost entry exists
grep -q "127.0.1.1.*peregrine" "${MOUNT_DIR}/etc/hosts" || \
    echo "127.0.1.1   peregrine" >> "${MOUNT_DIR}/etc/hosts"

log "Hostname set"

# ── Add Radxa QCS6490 apt repository ──────────────────────────────────────

step "Configure Radxa QCS6490 apt repository"

if [[ -f "${MOUNT_DIR}/etc/apt/sources.list.d/70-qcs6490-noble.list" ]]; then
    log "Radxa QCS6490 repo already configured"
else
    # Install the repo key and source list directly
    run_chroot "curl -s https://radxa-repo.github.io/qcs6490-noble/install.sh | sh" \
        || warn "Failed to add Radxa QCS6490 repo (may already be configured)"
fi

# ── Purge desktop and unnecessary packages ────────────────────────────────

step "Purge unnecessary packages"

# Remove snaps first (before purging snapd)
log "Removing snaps..."
run_chroot "snap list 2>/dev/null | tail -n+2 | awk '{print \$1}' | while read -r pkg; do snap remove --purge \"\$pkg\" 2>/dev/null || true; done" || true
run_chroot "rm -rf /snap /var/snap /var/lib/snapd" || true

log "Purging desktop environment, display server, and unused packages..."
run_chroot "
export DEBIAN_FRONTEND=noninteractive

# Mark packages to purge — use || true since some may not be installed
apt-get purge -y --auto-remove \
    snapd \
    gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
    gnome-terminal nautilus gnome-text-editor gnome-calculator gnome-calendar \
    gnome-characters gnome-clocks gnome-contacts gnome-disk-utility \
    gnome-font-viewer gnome-logs gnome-system-monitor gnome-tweaks \
    gnome-weather gnome-maps gnome-music gnome-photos \
    ubuntu-desktop ubuntu-desktop-minimal ubuntu-session ubuntu-release-upgrader-core \
    gdm3 mutter \
    xserver-xorg xserver-xorg-core x11-common x11-utils x11-xserver-utils \
    xwayland \
    pulseaudio pipewire pipewire-pulse wireplumber \
    wpa-supplicant iw wireless-tools wireless-regdb \
    bluez bluetooth \
    cups cups-browsed cups-daemon \
    modemmanager \
    accounts-daemon colord switcheroo-control power-profiles-daemon \
    udisks2 packagekit \
    fwupd \
    tracker tracker-miner-fs \
    evolution-data-server \
    geoclue-2.0 \
    gvfs gvfs-backends gvfs-daemons gvfs-fuse \
    firefox thunderbird \
    evince totem eog baobab yelp \
    fonts-noto-cjk fonts-noto-color-emoji \
    man-db info \
    whoopsie apport ubuntu-report popularity-contest \
    gnome-software update-notifier \
    2>/dev/null || true

# Aggressive autoremove
apt-get autoremove -y --purge 2>/dev/null || true
apt-get clean
rm -rf /var/lib/apt/lists/*
"

log "Desktop packages purged"

# ── Install required packages ─────────────────────────────────────────────

step "Install required packages"

run_chroot "
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    curl \
    wget \
    ffmpeg \
    alsa-utils \
    libsndfile1 \
    libasound2-dev \
    avahi-daemon \
    htop \
    plymouth \
    initramfs-tools \
    cloud-guest-utils \
    openssh-server \
    || true

# NPU packages
apt-get install -y fastrpc libcdsprpc1 || true

apt-get clean
rm -rf /var/lib/apt/lists/*
"

log "Required packages installed"

# ── Create assistant user ─────────────────────────────────────────────────

step "Create assistant user"

if chroot "${MOUNT_DIR}" id "${ASSISTANT_USER}" &>/dev/null; then
    log "User '${ASSISTANT_USER}' already exists"
else
    run_chroot "useradd -m -s /bin/bash -G audio,render ${ASSISTANT_USER}"
    log "Created user '${ASSISTANT_USER}'"
fi
run_chroot "usermod -aG audio,render ${ASSISTANT_USER}" || true

# ── Python virtual environment ────────────────────────────────────────────

step "Python virtual environment and packages"

run_chroot "python3 -m venv ${VENV_DIR}"

run_chroot "
${VENV_DIR}/bin/pip install --upgrade pip 2>/dev/null || true
${VENV_DIR}/bin/pip install \
    faster-whisper \
    piper-tts \
    paho-mqtt \
    numpy \
    scipy \
    scikit-learn \
    pathvalidate \
    requests \
    timezonefinder \
    || true

# openwakeword: --no-deps because tflite-runtime has no aarch64 wheel
${VENV_DIR}/bin/pip install --force-reinstall --no-deps openwakeword || true

# Download openwakeword resource models
${VENV_DIR}/bin/python3 -c '
import openwakeword
openwakeword.utils.download_models()
print(\"Resource models downloaded\")
' || true
"

log "Python packages installed"

# ── Download models ───────────────────────────────────────────────────────

step "Download models"

# NPU LLM model (Llama 3.2 1B)
log "Downloading NPU LLM model (Llama3.2-1B-1024-v68)..."
if [[ -d "${MOUNT_DIR}${NPU_MODEL_DIR}/models" ]]; then
    log "  NPU model already present in image"
else
    # Install modelscope temporarily in the chroot to download
    run_chroot "
pip3 install --break-system-packages -q modelscope 2>/dev/null || true
modelscope download --model radxa/Llama3.2-1B-1024-qairt-v68 --local ${NPU_MODEL_DIR} || true
chmod +x ${NPU_MODEL_DIR}/genie-t2t-run 2>/dev/null || true
pip3 uninstall -y modelscope 2>/dev/null || true
"
fi

# Piper TTS voice
log "Downloading Piper TTS voice..."
mkdir -p "${MOUNT_DIR}${PIPER_DIR}"
if [[ ! -f "${MOUNT_DIR}${PIPER_DIR}/${PIPER_VOICE}.onnx" ]]; then
    wget -q --show-progress -O "${MOUNT_DIR}${PIPER_DIR}/${PIPER_VOICE}.onnx" \
        "${PIPER_VOICE_URL}/${PIPER_VOICE}.onnx" || warn "Piper voice download failed"
    wget -q -O "${MOUNT_DIR}${PIPER_DIR}/${PIPER_VOICE}.onnx.json" \
        "${PIPER_VOICE_URL}/${PIPER_VOICE}.onnx.json" || true
fi

# Custom wake word model
log "Installing wake word model..."
mkdir -p "${MOUNT_DIR}${WAKE_MODEL_DIR}"
if [[ -f "${PROJECT_DIR}/models/hey_peregrine.onnx" ]]; then
    cp "${PROJECT_DIR}/models/hey_peregrine.onnx" "${MOUNT_DIR}${WAKE_MODEL_DIR}/"
    cp "${PROJECT_DIR}/models/hey_peregrine.onnx.data" "${MOUNT_DIR}${WAKE_MODEL_DIR}/" 2>/dev/null || true
    log "  Wake word model installed"
else
    warn "  hey_peregrine.onnx not found in ${PROJECT_DIR}/models/"
fi

log "Models installed"

# ── Copy application code ────────────────────────────────────────────────

step "Copy application code"

cp "${PROJECT_DIR}/src/assistant.py" "${MOUNT_DIR}${ASSISTANT_HOME}/assistant.py"
cp "${PROJECT_DIR}/src/genie_server.py" "${MOUNT_DIR}${ASSISTANT_HOME}/genie_server.py"

log "Application code copied"

# ── Install systemd services ─────────────────────────────────────────────

step "Install systemd services"

# Genie NPU server
cat > "${MOUNT_DIR}/etc/systemd/system/genie-server.service" << EOF
[Unit]
Description=Genie NPU LLM Server (Llama3.2-1B on Hexagon DSP)
After=network.target

[Service]
Type=simple
User=${ASSISTANT_USER}
Group=audio
SupplementaryGroups=render
WorkingDirectory=${ASSISTANT_HOME}
ExecStart=/usr/bin/python3 ${ASSISTANT_HOME}/genie_server.py
Restart=on-failure
RestartSec=5

Environment=HOME=${ASSISTANT_HOME}
Environment=PYTHONUNBUFFERED=1
Environment=GENIE_DIR=${NPU_MODEL_DIR}

[Install]
WantedBy=multi-user.target
EOF

# Voice assistant
cat > "${MOUNT_DIR}/etc/systemd/system/voice-assistant.service" << EOF
[Unit]
Description=Local Voice Assistant
After=network.target sound.target genie-server.service
Wants=genie-server.service

[Service]
Type=simple
User=${ASSISTANT_USER}
Group=audio
WorkingDirectory=${ASSISTANT_HOME}
ExecStartPre=/bin/sleep 5
ExecStart=${VENV_DIR}/bin/python3 ${ASSISTANT_HOME}/assistant.py
Restart=on-failure
RestartSec=10

Environment=HOME=${ASSISTANT_HOME}
Environment=WAKE_MODEL_PATH=${ASSISTANT_HOME}/models/hey_peregrine.onnx
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=-${ASSISTANT_HOME}/assistant.env

ProtectSystem=strict
ReadWritePaths=${ASSISTANT_HOME} /tmp
ProtectHome=tmpfs
BindPaths=${ASSISTANT_HOME}
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# CPU performance governor
cat > "${MOUNT_DIR}/etc/systemd/system/cpu-performance.service" << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Hardware power-down (GPU, display, camera, USB power management)
cat > "${MOUNT_DIR}/etc/systemd/system/power-save-hw.service" << 'PWREOF'
[Unit]
Description=Disable unused QCS6490 hardware for power savings
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  for gpu in /sys/class/devfreq/*gpu* /sys/class/devfreq/*3d00000*; do \
    [ -f "$gpu/governor" ] && echo powersave > "$gpu/governor"; \
    min=$(awk "{print \$1}" "$gpu/available_frequencies" 2>/dev/null); \
    [ -n "$min" ] && echo "$min" > "$gpu/max_freq" && echo "$min" > "$gpu/min_freq"; \
  done; \
  for drv in msm_dsi msm_dp msm_mdss camss; do \
    d="/sys/bus/platform/drivers/$drv"; [ -d "$d" ] && \
    for dev in "$d"/*/; do n=$(basename "$dev"); \
      [ "$n" != module ] && [ "$n" != uevent ] && echo "$n" > "$d/unbind" 2>/dev/null; \
    done; \
  done; \
  rfkill block wifi 2>/dev/null || true; \
  for dev in /sys/bus/usb/devices/*/power/control; do \
    dp=$(dirname "$dev"); audio=false; \
    for ifc in "$dp"/*:*/bInterfaceClass; do \
      [ -f "$ifc" ] && grep -q 01 "$ifc" 2>/dev/null && audio=true && break; \
    done; \
    $audio && echo on > "$dev" 2>/dev/null || echo auto > "$dev" 2>/dev/null; \
  done; \
  true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
PWREOF

# First-boot service
cp "${SCRIPT_DIR}/firstboot/peregrine-firstboot.sh" "${MOUNT_DIR}/usr/local/bin/peregrine-firstboot.sh"
chmod +x "${MOUNT_DIR}/usr/local/bin/peregrine-firstboot.sh"
cp "${SCRIPT_DIR}/firstboot/peregrine-firstboot.service" "${MOUNT_DIR}/etc/systemd/system/"

# Enable all services
run_chroot "
systemctl enable genie-server 2>/dev/null || true
systemctl enable voice-assistant 2>/dev/null || true
systemctl enable cpu-performance 2>/dev/null || true
systemctl enable power-save-hw 2>/dev/null || true
systemctl enable peregrine-firstboot 2>/dev/null || true
systemctl enable avahi-daemon 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
"

log "Services installed and enabled"

# ── Sysctl tuning ────────────────────────────────────────────────────────

step "Kernel tuning"

cat > "${MOUNT_DIR}/etc/sysctl.d/90-assistant.conf" << 'EOF'
# Reduce swap pressure — keep inference models in RAM
vm.swappiness = 10

# Reduce filesystem dirty page writebacks (less I/O contention)
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5

# Increase inotify limits
fs.inotify.max_user_watches = 65536

# Reduce kernel log verbosity
kernel.printk = 4 4 1 7
EOF

log "Sysctl tuning installed"

# ── Disable & mask unnecessary services ──────────────────────────────────

step "Mask unnecessary services"

run_chroot "
MASK_SERVICES=(
    snapd.service snapd.socket snapd.seeded.service
    cups.service cups-browsed.service
    bluetooth.service
    ModemManager.service
    fwupd.service
    packagekit.service
    accounts-daemon.service
    colord.service
    switcheroo-control.service
    power-profiles-daemon.service
    udisks2.service
    wpa_supplicant.service
    NetworkManager-wait-online.service
    apt-daily.timer
    apt-daily-upgrade.timer
    motd-news.timer
    man-db.timer
    e2scrub_all.timer
    fstrim.timer
    unattended-upgrades.service
    whoopsie.service
    apport.service
    gdm3.service gdm.service lightdm.service sddm.service
)

for svc in \"\${MASK_SERVICES[@]}\"; do
    systemctl mask \"\$svc\" 2>/dev/null || true
done
"

log "Unnecessary services masked"

# ── Disable WiFi completely ──────────────────────────────────────────────

step "Disable WiFi (LAN only)"

# Blacklist WiFi kernel modules
cat > "${MOUNT_DIR}/etc/modprobe.d/disable-wifi.conf" << 'EOF'
# TrailCurrent Peregrine: WiFi disabled — board uses LAN only
blacklist ath10k_core
blacklist ath10k_pci
blacklist ath10k_snoc
blacklist ath11k
blacklist ath11k_pci
blacklist ath
blacklist cfg80211
blacklist mac80211
EOF

# Ensure rfkill blocks WiFi at boot
mkdir -p "${MOUNT_DIR}/etc/systemd/system/rfkill-wifi.service.d"
cat > "${MOUNT_DIR}/etc/systemd/system/rfkill-block-wifi.service" << 'EOF'
[Unit]
Description=Block WiFi via rfkill
After=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill block wifi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run_chroot "systemctl enable rfkill-block-wifi 2>/dev/null || true"

log "WiFi disabled (kernel modules blacklisted, rfkill block at boot)"

# ── Disable PulseAudio/PipeWire ──────────────────────────────────────────

step "Disable PulseAudio/PipeWire"

run_chroot "
for svc in pulseaudio pipewire pipewire-pulse wireplumber; do
    systemctl --global disable \"\$svc.service\" \"\$svc.socket\" 2>/dev/null || true
done
"

# System-wide autospawn disable
mkdir -p "${MOUNT_DIR}/etc/pulse"
echo "autospawn = no" > "${MOUNT_DIR}/etc/pulse/client.conf"

# Per-user disable
mkdir -p "${MOUNT_DIR}${ASSISTANT_HOME}/.config/pulse"
echo "autospawn = no" > "${MOUNT_DIR}${ASSISTANT_HOME}/.config/pulse/client.conf"

log "Audio daemons disabled"

# ── Default assistant.env ────────────────────────────────────────────────

step "Create default assistant.env"

cat > "${MOUNT_DIR}${ASSISTANT_HOME}/assistant.env" << 'ENVEOF'
# Voice assistant environment config — persists across deploys.
# Edit with: nano ~/assistant.env
# Then restart: sudo systemctl restart voice-assistant

# MQTT
#MQTT_BROKER=192.168.x.x
#MQTT_PORT=8883
#MQTT_USE_TLS=true
#MQTT_CA_CERT=/home/assistant/ca.pem
#MQTT_USERNAME=
#MQTT_PASSWORD=

# Audio tuning
#WAKE_THRESHOLD=0.5
#SILENCE_THRESHOLD=500
#SILENCE_DURATION=1.5
ENVEOF

log "Default assistant.env created"

# ── Plymouth boot splash ────────────────────────────────────────────────

step "Install Plymouth boot splash"

PLYMOUTH_THEME_DIR="${MOUNT_DIR}/usr/share/plymouth/themes/trailcurrent"
mkdir -p "$PLYMOUTH_THEME_DIR"
cp "${SCRIPT_DIR}/plymouth/trailcurrent.plymouth" "$PLYMOUTH_THEME_DIR/"
cp "${SCRIPT_DIR}/plymouth/trailcurrent.script" "$PLYMOUTH_THEME_DIR/"
cp "${SCRIPT_DIR}/plymouth/logo.png" "$PLYMOUTH_THEME_DIR/"
cp "${SCRIPT_DIR}/plymouth/background.png" "$PLYMOUTH_THEME_DIR/"

run_chroot "
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
    default.plymouth /usr/share/plymouth/themes/trailcurrent/trailcurrent.plymouth 200 2>/dev/null || true
update-alternatives --set default.plymouth \
    /usr/share/plymouth/themes/trailcurrent/trailcurrent.plymouth 2>/dev/null || true
"

log "Plymouth theme installed"

# ── ASCII art branding ───────────────────────────────────────────────────

step "Install ASCII art branding"

# Remove stock Ubuntu MOTD scripts
rm -f "${MOUNT_DIR}/etc/update-motd.d/00-header"
rm -f "${MOUNT_DIR}/etc/update-motd.d/10-help-text"
rm -f "${MOUNT_DIR}/etc/update-motd.d/50-motd-news"
rm -f "${MOUNT_DIR}/etc/update-motd.d/85-fwupd"
rm -f "${MOUNT_DIR}/etc/update-motd.d/90-updates-available"
rm -f "${MOUNT_DIR}/etc/update-motd.d/91-release-upgrade"
rm -f "${MOUNT_DIR}/etc/update-motd.d/92-unattended-upgrades"
rm -f "${MOUNT_DIR}/etc/update-motd.d/95-hwe-eol"
rm -f "${MOUNT_DIR}/etc/update-motd.d/97-overlayroot"
rm -f "${MOUNT_DIR}/etc/update-motd.d/98-fsck-at-reboot"

# Install TrailCurrent MOTD
cp "${SCRIPT_DIR}/branding/10-trailcurrent" "${MOUNT_DIR}/etc/update-motd.d/10-trailcurrent"
chmod +x "${MOUNT_DIR}/etc/update-motd.d/10-trailcurrent"

# Install console issue (login screen)
cp "${SCRIPT_DIR}/branding/issue-trailcurrent" "${MOUNT_DIR}/etc/issue"

log "Branding installed"

# ── Boot speed optimizations ─────────────────────────────────────────────

step "Boot speed optimizations"

# Set default target to multi-user (no graphical desktop)
run_chroot "systemctl set-default multi-user.target"

# initramfs: only include modules needed for boot, use fast compression
if [[ -f "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf" ]]; then
    sed -i 's/^MODULES=.*/MODULES=dep/' "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
    sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
    # Add if not present
    grep -q "^MODULES=" "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf" || \
        echo "MODULES=dep" >> "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
    grep -q "^COMPRESS=" "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf" || \
        echo "COMPRESS=zstd" >> "${MOUNT_DIR}/etc/initramfs-tools/initramfs.conf"
fi

# systemd timeout — fail fast on stuck services
mkdir -p "${MOUNT_DIR}/etc/systemd/system.conf.d"
cat > "${MOUNT_DIR}/etc/systemd/system.conf.d/timeout.conf" << 'EOF'
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=15s
EOF

# Update kernel command line for quiet boot with splash
# Look for grub config or extlinux config
for grub_cfg in "${MOUNT_DIR}/etc/default/grub"; do
    if [[ -f "$grub_cfg" ]]; then
        # Add boot parameters
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0 vt.global_cursor_default=0 rd.systemd.show_status=0"/' "$grub_cfg"
        run_chroot "update-grub 2>/dev/null" || true
        break
    fi
done

# Also check for extlinux (common on ARM boards)
EXTLINUX_CONF="${MOUNT_DIR}/boot/extlinux/extlinux.conf"
if [[ -f "$EXTLINUX_CONF" ]]; then
    if ! grep -q "quiet" "$EXTLINUX_CONF"; then
        sed -i '/^[[:space:]]*append/s/$/ quiet splash loglevel=0 vt.global_cursor_default=0 rd.systemd.show_status=0/' "$EXTLINUX_CONF"
    fi
fi

# Rebuild initramfs with optimizations
run_chroot "update-initramfs -u 2>/dev/null" || warn "initramfs update failed (non-fatal)"

log "Boot optimizations applied"

# ── File ownership ───────────────────────────────────────────────────────

step "Fix file ownership"

run_chroot "chown -R ${ASSISTANT_USER}:${ASSISTANT_USER} ${ASSISTANT_HOME}"

# Enable linger for the assistant user (persistent user session)
run_chroot "loginctl enable-linger ${ASSISTANT_USER} 2>/dev/null" || true

log "Ownership fixed"

# ── Clean up for golden image ────────────────────────────────────────────

step "Clean up for golden image"

# Clear machine-id (regenerated on first boot)
echo "" > "${MOUNT_DIR}/etc/machine-id"
rm -f "${MOUNT_DIR}/var/lib/dbus/machine-id"

# Remove SSH host keys (regenerated on first boot)
rm -f "${MOUNT_DIR}/etc/ssh/ssh_host_"*

# Clean apt cache
run_chroot "apt-get clean 2>/dev/null" || true
rm -rf "${MOUNT_DIR}/var/lib/apt/lists/"*

# Clean pip cache
rm -rf "${MOUNT_DIR}/root/.cache/pip"
rm -rf "${MOUNT_DIR}${ASSISTANT_HOME}/.cache/pip"

# Clean temporary files
rm -f "${MOUNT_DIR}/var/log/"*.log
rm -rf "${MOUNT_DIR}/tmp/"*
rm -rf "${MOUNT_DIR}/var/tmp/"*

# Remove qemu binary (not needed on actual board)
rm -f "${MOUNT_DIR}/usr/bin/qemu-aarch64-static"

# Remove policy-rc.d (was preventing service startup during build)
rm -f "${MOUNT_DIR}/usr/sbin/policy-rc.d"

# Clear bash history
rm -f "${MOUNT_DIR}/root/.bash_history"
rm -f "${MOUNT_DIR}${ASSISTANT_HOME}/.bash_history"

log "Golden image cleanup complete"

# ── Unmount and shrink ───────────────────────────────────────────────────

step "Unmount and shrink image"

# Unmount in reverse order
umount -lf "${MOUNT_DIR}/dev/pts" 2>/dev/null || true
umount -lf "${MOUNT_DIR}/dev" 2>/dev/null || true
umount -lf "${MOUNT_DIR}/proc" 2>/dev/null || true
umount -lf "${MOUNT_DIR}/sys" 2>/dev/null || true
umount -lf "${MOUNT_DIR}/run" 2>/dev/null || true
umount -lf "${MOUNT_DIR}/boot/efi" 2>/dev/null || true
umount -lf "${MOUNT_DIR}" 2>/dev/null || true
MOUNTED=false

# Shrink the root filesystem to minimum size
log "Shrinking root filesystem..."
e2fsck -fy "$ROOT_PART" 2>/dev/null || true
resize2fs -M "$ROOT_PART" 2>/dev/null || true

# Get the new filesystem size in blocks
BLOCK_COUNT=$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | grep "Block count:" | awk '{print $3}')
BLOCK_SIZE=$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | grep "Block size:" | awk '{print $3}')

if [[ -n "$BLOCK_COUNT" && -n "$BLOCK_SIZE" ]]; then
    FS_BYTES=$((BLOCK_COUNT * BLOCK_SIZE))
    # Add 10% headroom
    FS_BYTES=$((FS_BYTES + FS_BYTES / 10))
    log "  Shrunk root filesystem to ~$(( FS_BYTES / 1024 / 1024 )) MB"
fi

# Detach loop device
losetup -d "$LOOP_DEV" 2>/dev/null || true
LOOP_DEV=""

# Note: We don't truncate the image file to preserve the partition table.
# The resulting image will be the same size as the stock image but with
# mostly empty space after the shrunk filesystem. xz compression will
# handle this efficiently (empty space compresses to nearly nothing).

log "Image prepared for compression"

# ── Compress ─────────────────────────────────────────────────────────────

step "Compress image"

OUTPUT_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img.xz"
log "Compressing to ${OUTPUT_FILE} (this will take a while)..."
xz -9 --threads=0 "${IMG_FILE}"
mv "${IMG_FILE}.xz" "${OUTPUT_FILE}"

FINAL_SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)
log "Compressed image: ${OUTPUT_FILE} (${FINAL_SIZE})"

# ── Done ─────────────────────────────────────────────────────────────────

step "Build complete!"

echo ""
echo "Output: ${OUTPUT_FILE} (${FINAL_SIZE})"
echo ""
echo "To flash a board:"
echo ""
echo "  1. Enter EDL mode (hold EDL button + connect power)"
echo ""
echo "  2. Flash SPI firmware (first time only):"
echo "     sudo edl-ng --memory spinor --loader prog_firehose_ddr.elf \\"
echo "         rawprogram rawprogram0.xml patch0.xml"
echo ""
echo "  3. Flash the image:"
echo "     xz -dk ${OUTPUT_FILE}"
echo "     sudo edl-ng --loader prog_firehose_ddr.elf --memory nvme \\"
echo "         write-sector 0 ${OUTPUT_DIR}/${IMAGE_NAME}.img"
echo ""
echo "  4. Reset: sudo edl-ng --loader prog_firehose_ddr.elf reset"
echo ""
echo "  5. Wait ~60s for first boot (SSH keys + partition expansion + reboot)"
echo ""
echo "  6. Connect: ssh root@peregrine.local"
echo ""
echo "  7. Configure: ./configure-board.sh peregrine.local"
echo ""
