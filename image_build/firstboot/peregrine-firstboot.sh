#!/usr/bin/env bash
# ============================================================================
# Peregrine First-Boot Script
# Runs once on the first boot after flashing the golden image.
# Regenerates per-board identity, expands the root filesystem, then disables
# itself so it never runs again.
# ============================================================================

set -euo pipefail

log() { echo "[firstboot] $*"; }

# 1. Regenerate machine-id (was cleared in the golden image)
if [[ ! -s /etc/machine-id ]]; then
    systemd-machine-id-setup
    log "Regenerated /etc/machine-id"
fi

# 2. Regenerate SSH host keys (were removed in the golden image)
if ! ls /etc/ssh/ssh_host_*_key &>/dev/null; then
    dpkg-reconfigure -f noninteractive openssh-server
    systemctl restart sshd
    log "Regenerated SSH host keys"
fi

# 3. Expand root partition to fill the NVMe
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -ndo PKNAME "$ROOT_DEV" 2>/dev/null || echo "")
ROOT_PART=$(echo "$ROOT_DEV" | grep -oP 'p?\d+$')

if [[ -n "$ROOT_DISK" && -n "$ROOT_PART" ]]; then
    PART_NUM=$(echo "$ROOT_PART" | grep -oP '\d+$')
    log "Expanding /dev/${ROOT_DISK} partition ${PART_NUM}..."
    growpart "/dev/${ROOT_DISK}" "${PART_NUM}" 2>/dev/null || true
    resize2fs "$ROOT_DEV" 2>/dev/null || true
    log "Root filesystem expanded"
else
    log "WARNING: Could not determine root partition for expansion"
fi

# 4. Disable this service so it never runs again
systemctl disable peregrine-firstboot.service
log "First-boot complete — service disabled"

# 5. Reboot to apply all changes cleanly
log "Rebooting..."
reboot
