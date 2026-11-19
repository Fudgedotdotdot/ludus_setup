#!/bin/bash
#
# Ludus unattended installer
# ---------------------------------------------------------------------------
# Runs once on first boot (via ludus-firstboot.service) as root, after the
# Debian preseed install has completed.
#
# What it does:
#   1. Waits for network connectivity
#   2. Resolves the latest stable Ludus release tag (skips -beta)
#   3. Installs the ludus client to /usr/local/bin/ludus
#   4. Downloads the ludus-server binary and runs it with --no-prompt
#
# Why not just run `curl https://ludus.cloud/install | bash`?
#   The official install.sh is interactive: every prompt is `read </dev/tty`
#   (so piping answers to stdin does nothing) and it launches the server
#   WITHOUT --no-prompt, which starts the interactive TUI. Neither can run
#   unattended under systemd. Instead we do the same downloads and pass
#   --no-prompt to the server, which is the documented-in-source path for
#   unattended installs (see ludus-server/args.go and checks.go).
#
# The ludus-server binary then:
#   - copies itself to /opt/ludus/ludus-server
#   - auto-generates /opt/ludus/config.yml from detected network settings
#     (interface, local/public IP, gateway, netmask) plus sane defaults
#   - installs ansible and runs the embedded Ansible playbooks, which install
#     Proxmox VE and configure the host
#   - reboots; the install resumes automatically across reboots via the
#     ludus-install.service unit the playbook creates, until stage 3 is done.
#
# Monitor progress with:  ludus-install-status
# ---------------------------------------------------------------------------

set -euo pipefail

LOG_FILE="/var/log/ludus-install.log"
PROJECT_ID="54052321"
GITLAB_API="https://gitlab.com/api/v4/projects/${PROJECT_ID}"
GENERIC_BASE="${GITLAB_API}/packages/generic/ludus"
WORK_DIR="/root/ludus-install"
SERVICE_NAME="ludus-firstboot.service"

exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "=== Ludus unattended install starting ==="

# ---------------------------------------------------------------------------
# 1. Wait for network
# ---------------------------------------------------------------------------
log "Waiting for network connectivity..."
for _ in $(seq 1 60); do
    if curl -fsSL --max-time 5 https://gitlab.com >/dev/null 2>&1; then
        log "Network is up"
        break
    fi
    sleep 5
done

# ---------------------------------------------------------------------------
# 2. Resolve the latest stable release tag
# ---------------------------------------------------------------------------
log "Resolving latest stable Ludus release..."
TAG="$(curl -fsSL "${GITLAB_API}/repository/tags" \
        | tr ',' '\n' \
        | grep '"name"' \
        | cut -d'"' -f4 \
        | grep -v -- '-beta' \
        | head -n1 || true)"
if [ -z "${TAG}" ]; then
    log "ERROR: could not determine latest Ludus release tag"
    exit 1
fi
log "Latest stable release: ${TAG}"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# ---------------------------------------------------------------------------
# 3. Fetch checksums (best effort) for verification
# ---------------------------------------------------------------------------
if curl -fsSL "${GENERIC_BASE}/${TAG}/ludus_${TAG}_checksums.txt" -o checksums.txt; then
    log "Downloaded checksums file"
else
    log "WARNING: could not download checksums file; skipping verification"
    : > checksums.txt
fi

verify_checksum() {
    local file="$1"
    [ -s checksums.txt ] || return 0
    grep "$(basename "${file}")" checksums.txt > filtered_checksum.txt || return 0
    [ -s filtered_checksum.txt ] || return 0
    if sha256sum -c filtered_checksum.txt >/dev/null 2>&1; then
        log "Checksum verified: $(basename "${file}")"
    else
        log "ERROR: checksum verification failed for $(basename "${file}")"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 4. Install the ludus client
#    File name must match the entry in the checksums file: ludus-client_linux-amd64
# ---------------------------------------------------------------------------
CLIENT_ASSET="ludus-client_linux-amd64-${TAG}"
log "Downloading ${CLIENT_ASSET}..."
curl -fsSL "${GENERIC_BASE}/${TAG}/${CLIENT_ASSET}" -o ludus-client_linux-amd64
verify_checksum ludus-client_linux-amd64
install -m 0755 ludus-client_linux-amd64 /usr/local/bin/ludus
log "Installed ludus client to /usr/local/bin/ludus"

# ---------------------------------------------------------------------------
# 5. Download the ludus server binary
#    File name must match the entry in the checksums file: ludus-server
# ---------------------------------------------------------------------------
SERVER_ASSET="ludus-server-${TAG}"
log "Downloading ${SERVER_ASSET}..."
curl -fsSL "${GENERIC_BASE}/${TAG}/${SERVER_ASSET}" -o ludus-server
verify_checksum ludus-server
chmod 0755 ludus-server

# Sanity check: this release must support unattended install
if ! ./ludus-server --help 2>&1 | grep -q -- '--no-prompt'; then
    log "ERROR: Ludus ${TAG} does not support --no-prompt; a newer release is required"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Run the server installer non-interactively
# ---------------------------------------------------------------------------
# Disable this oneshot unit first, so the post-install reboots do not re-run
# this script (the Ansible playbook installs its own resume unit).
log "Disabling ${SERVICE_NAME} to prevent re-run after reboot"
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

log "Running: ludus-server --no-prompt  (installs Proxmox VE, then reboots)"
./ludus-server --no-prompt

log "=== Ludus unattended install stage finished; a reboot may follow ==="
log "Check progress after reboot with: ludus-install-status"
