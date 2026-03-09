#!/bin/bash
#
# TeslaUSB NAS Archive Script
#
# Syncs TeslaCam footage to a NAS when connected to home WiFi.
# Designed to run as a systemd oneshot service on a timer.
#
# Safety rules:
# - Only runs in "present" mode (USB serving to Tesla)
# - Only runs when connected to home WiFi SSID
# - Uses nsenter for all mount operations (required in Pi namespace)
# - Always unmounts NAS on exit via trap
# - Writes status atomically (temp + fsync + rename)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/config.sh
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Constants
# ============================================================================
NAS_MOUNT="/mnt/nas_archive"
STATUS_DIR="/run/teslausb"
STATUS_FILE="$STATUS_DIR/nas_archive_status.json"
STATUS_TMP="$STATUS_DIR/nas_archive_status.tmp"
LOGS_DIR="$GADGET_DIR/logs"
LOG_FILE="$LOGS_DIR/nas_archive_last.log"
HISTORY_FILE="$LOGS_DIR/nas_archive_history.json"
HISTORY_MAX=100
PART1_RO_MOUNT="$MNT_DIR/part1-ro"
LOG_PREFIX="nas_archive"
RUN_START="$(date +%s)"

# ============================================================================
# Logging helpers
# ============================================================================
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LOG_PREFIX] INFO:  $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LOG_PREFIX] ERROR: $*" >&2; }

# ============================================================================
# Status file helpers (atomic write)
# ============================================================================
write_status() {
  local status="$1"
  local message="$2"
  local files_synced="${3:-0}"
  local last_error="${4:-}"
  local bytes_transferred="${5:-0}"

  mkdir -p "$STATUS_DIR"

  cat > "$STATUS_TMP" <<EOF
{
  "enabled": $NAS_ARCHIVE_ENABLED,
  "status": "$status",
  "message": "$message",
  "last_sync": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "files_synced": $files_synced,
  "bytes_transferred": $bytes_transferred,
  "last_error": "$last_error"
}
EOF

  # Atomic rename after fsync
  sync "$STATUS_TMP" 2>/dev/null || true
  mv -f "$STATUS_TMP" "$STATUS_FILE"
}

# ============================================================================
# History file helpers
# ============================================================================
append_history() {
  local status="$1"
  local files_synced="${2:-0}"
  local bytes_transferred="${3:-0}"
  local duration="${4:-0}"
  local error="${5:-}"

  mkdir -p "$LOGS_DIR"

  local entry
  entry="$(printf '{"timestamp":"%s","status":"%s","files_synced":%s,"bytes_transferred":%s,"duration_seconds":%s,"ssid":"%s","error":"%s"}' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$status" \
    "$files_synced" \
    "$bytes_transferred" \
    "$duration" \
    "${CURRENT_SSID:-}" \
    "$error")"

  # Read existing history or start fresh
  local existing="[]"
  if [ -f "$HISTORY_FILE" ]; then
    existing="$(cat "$HISTORY_FILE" 2>/dev/null || echo '[]')"
  fi

  # Prepend new entry, keep last HISTORY_MAX entries, write atomically
  local tmp="$HISTORY_FILE.tmp"
  python3 -c "
import json, sys
entry = json.loads(sys.argv[1])
try:
    history = json.loads(sys.argv[2])
except:
    history = []
history.insert(0, entry)
history = history[:$HISTORY_MAX]
print(json.dumps(history, indent=2))
" "$entry" "$existing" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HISTORY_FILE" || true
}

# ============================================================================
# Slack notification helper
# ============================================================================
slack_notify() {
  local message="$1"
  if [ -z "$NAS_ARCHIVE_SLACK_WEBHOOK" ]; then
    return 0
  fi
  local payload
  payload="$(printf '{"text": "%s"}' "$(echo "$message" | sed 's/"/\\"/g; s/$/\\n/' | tr -d '\n')")"
  curl -s -X POST -H 'Content-type: application/json' \
    --data "$payload" \
    --max-time 10 \
    "$NAS_ARCHIVE_SLACK_WEBHOOK" >/dev/null 2>&1 || true
}

# ============================================================================
# Cleanup / unmount on exit
# ============================================================================
NAS_MOUNTED=false

cleanup() {
  if [ "$NAS_MOUNTED" = "true" ]; then
    log_info "Unmounting NAS at $NAS_MOUNT..."
    nsenter --mount=/proc/1/ns/mnt -- umount "$NAS_MOUNT" 2>/dev/null || \
      nsenter --mount=/proc/1/ns/mnt -- umount -l "$NAS_MOUNT" 2>/dev/null || \
      log_error "Failed to unmount NAS (may already be unmounted)"
    NAS_MOUNTED=false
  fi
}

trap cleanup EXIT

# ============================================================================
# Setup log file
# ============================================================================
mkdir -p "$LOGS_DIR"
# Truncate log at start of each run
: > "$LOG_FILE"
# Redirect all output to log file AND stdout (for journald)
exec > >(tee -a "$LOG_FILE") 2>&1

# ============================================================================
# Check: NAS archiving enabled
# ============================================================================
if [ "$NAS_ARCHIVE_ENABLED" != "true" ]; then
  log_info "NAS archiving is disabled in config. Exiting."
  mkdir -p "$STATUS_DIR"
  write_status "disabled" "NAS archiving is disabled" 0 "" 0
  exit 0
fi

# ============================================================================
# Check: current WiFi SSID matches home SSID
# ============================================================================
CURRENT_SSID=""
if command -v nmcli &>/dev/null; then
  CURRENT_SSID="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '/^yes:/{print $2}' | head -1 || true)"
fi

if [ -z "$CURRENT_SSID" ]; then
  # Fallback: try iw
  if command -v iw &>/dev/null; then
    CURRENT_SSID="$(iw dev wlan0 link 2>/dev/null | awk '/SSID:/{print $2}' | head -1 || true)"
  fi
fi

if [ "$CURRENT_SSID" != "$NAS_ARCHIVE_HOME_SSID" ]; then
  log_info "Not on home WiFi (current: '${CURRENT_SSID:-none}', home: '$NAS_ARCHIVE_HOME_SSID'). Skipping."
  write_status "not_home" "Not connected to home WiFi ('${CURRENT_SSID:-none}')" 0 "" 0
  exit 0
fi

log_info "On home WiFi '$CURRENT_SSID'. Proceeding with archive check."

# ============================================================================
# Check: USB gadget in "present" mode
# ============================================================================
if [ ! -f "$STATE_FILE" ] || [ "$(cat "$STATE_FILE")" != "present" ]; then
  log_info "Not in present mode. Skipping NAS archive."
  write_status "skipped" "Not in present mode" 0 "" 0
  exit 0
fi

# ============================================================================
# Check: part1-ro is mounted
# ============================================================================
if ! nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "$PART1_RO_MOUNT" 2>/dev/null; then
  log_info "Part1-ro not mounted at $PART1_RO_MOUNT. Skipping."
  write_status "skipped" "TeslaCam drive not mounted" 0 "" 0
  exit 0
fi

TESLACAM_DIR="$PART1_RO_MOUNT/TeslaCam"
if [ ! -d "$TESLACAM_DIR" ]; then
  log_info "TeslaCam directory not found at $TESLACAM_DIR. Nothing to sync."
  write_status "ok" "No TeslaCam footage found" 0 "" 0
  exit 0
fi

# ============================================================================
# Mount NAS via CIFS
# ============================================================================
log_info "Mounting NAS //$NAS_ARCHIVE_SMB_HOST/$NAS_ARCHIVE_SMB_SHARE..."

nsenter --mount=/proc/1/ns/mnt -- mkdir -p "$NAS_MOUNT"

MOUNT_OPTS="vers=$NAS_ARCHIVE_SMB_VERSION,username=$NAS_ARCHIVE_SMB_USER"
if [ -n "$NAS_ARCHIVE_SMB_PASSWORD" ]; then
  MOUNT_OPTS="$MOUNT_OPTS,password=$NAS_ARCHIVE_SMB_PASSWORD"
fi
# Use noserverino to avoid inode conflicts on Synology
MOUNT_OPTS="$MOUNT_OPTS,noserverino,file_mode=0644,dir_mode=0755"

if ! nsenter --mount=/proc/1/ns/mnt -- mount -t cifs \
    "//$NAS_ARCHIVE_SMB_HOST/$NAS_ARCHIVE_SMB_SHARE" \
    "$NAS_MOUNT" \
    -o "$MOUNT_OPTS" 2>/dev/null; then
  log_error "Failed to mount NAS //$NAS_ARCHIVE_SMB_HOST/$NAS_ARCHIVE_SMB_SHARE"
  write_status "error" "Failed to mount NAS" 0 "CIFS mount failed" 0
  append_history "error" 0 0 "$(( $(date +%s) - RUN_START ))" "CIFS mount failed"
  exit 0  # Exit 0 so systemd doesn't mark it as failed (network may just be unavailable)
fi

NAS_MOUNTED=true
log_info "NAS mounted at $NAS_MOUNT"

# ============================================================================
# Rsync TeslaCam footage to NAS
# ============================================================================
log_info "Starting rsync from $TESLACAM_DIR/ to $NAS_MOUNT/..."

RSYNC_OUTPUT="$(mktemp)"

# Dry-run first to count pending files for Slack notification
PENDING_FILES=0
DRY_RUN_OUT="$(mktemp)"
if nsenter --mount=/proc/1/ns/mnt -- rsync -a \
    --ignore-existing \
    --no-perms --no-owner --no-group \
    --omit-dir-times \
    --dry-run --stats \
    "$TESLACAM_DIR/" \
    "$NAS_MOUNT/" \
    > "$DRY_RUN_OUT" 2>&1; then
  PENDING_FILES="$(grep -oP 'Number of regular files transferred: \K[0-9,]+' "$DRY_RUN_OUT" | tr -d ',' || echo 0)"
  PENDING_FILES="${PENDING_FILES:-0}"
fi
rm -f "$DRY_RUN_OUT"

log_info "Files pending transfer: $PENDING_FILES"

if [ "$PENDING_FILES" -gt 0 ]; then
  slack_notify "TeslaUSB: Starting NAS archive — $PENDING_FILES file(s) to sync to //$NAS_ARCHIVE_SMB_HOST/$NAS_ARCHIVE_SMB_SHARE"
fi

# --ignore-existing: never overwrite files already on NAS (safe for live recording)
# --no-perms --no-owner --no-group: CIFS doesn't support Unix permissions
# --omit-dir-times: avoid errors on CIFS directory timestamps
nsenter --mount=/proc/1/ns/mnt -- rsync -a \
    --ignore-existing \
    --no-perms --no-owner --no-group \
    --omit-dir-times \
    --stats \
    "$TESLACAM_DIR/" \
    "$NAS_MOUNT/" \
    > "$RSYNC_OUTPUT" 2>&1
RSYNC_EXIT=$?
# Exit code 24 = files vanished during transfer (normal with live TeslaCam recording)
[ "$RSYNC_EXIT" -eq 24 ] && RSYNC_EXIT=0
if [ "$RSYNC_EXIT" -eq 0 ]; then

  # Parse stats from rsync --stats output
  FILES_SYNCED="$(grep -oP 'Number of regular files transferred: \K[0-9,]+' "$RSYNC_OUTPUT" | tr -d ',' || echo 0)"
  FILES_SYNCED="${FILES_SYNCED:-0}"
  BYTES_TRANSFERRED="$(grep -oP 'Total transferred file size: \K[0-9,]+' "$RSYNC_OUTPUT" | tr -d ',' || echo 0)"
  BYTES_TRANSFERRED="${BYTES_TRANSFERRED:-0}"

  DURATION="$(( $(date +%s) - RUN_START ))"

  log_info "Rsync complete. Files transferred: $FILES_SYNCED, Bytes: $BYTES_TRANSFERRED, Duration: ${DURATION}s"
  cat "$RSYNC_OUTPUT" | while IFS= read -r line; do log_info "  $line"; done

  # Optionally delete local files after successful archive
  if [ "$NAS_ARCHIVE_DELETE_AFTER" = "true" ] && [ "$FILES_SYNCED" -gt 0 ]; then
    log_info "delete_after_archive enabled — requires edit mode for writes. Skipping delete."
  fi

  write_status "ok" "Sync complete" "$FILES_SYNCED" "" "$BYTES_TRANSFERRED"
  append_history "ok" "$FILES_SYNCED" "$BYTES_TRANSFERRED" "$DURATION" ""

  if [ "$FILES_SYNCED" -gt 0 ]; then
    slack_notify "TeslaUSB: Archive complete — $FILES_SYNCED file(s) synced (${DURATION}s)"
  fi

else
  RSYNC_ERROR="$(grep -v '^$' "$RSYNC_OUTPUT" | tail -1 | tr '"' "'" | tr '\n' ' ') (code $RSYNC_EXIT)"
  DURATION="$(( $(date +%s) - RUN_START ))"
  log_error "Rsync failed: $RSYNC_ERROR"
  cat "$RSYNC_OUTPUT" | while IFS= read -r line; do log_info "  $line"; done
  write_status "error" "Rsync failed" 0 "$RSYNC_ERROR" 0
  append_history "error" 0 0 "$DURATION" "$RSYNC_ERROR"
  slack_notify "TeslaUSB: Archive FAILED — $RSYNC_ERROR"
fi

rm -f "$RSYNC_OUTPUT"

log_info "NAS archive run complete."
