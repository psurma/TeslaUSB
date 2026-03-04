# Changelog

## [Unreleased]

### Added
- NAS archiving feature: automatically sync TeslaCam footage to a NAS when connected to home WiFi
  - `config.yaml`: new `nas_archive` section with host, share, credentials, SSID, and delete-after settings
  - `scripts/config.sh`: exports `NAS_ARCHIVE_*` environment variables for bash scripts
  - `scripts/nas_archive.sh`: core archiving script using rsync over CIFS; uses `nsenter` for safe mounts, trap-based cleanup, atomic status writes
  - `templates/nas_archive.service`: systemd oneshot service template
  - `templates/nas_archive.timer`: systemd timer (runs 2min after boot, then every 5min)
  - `scripts/web/services/archive_service.py`: Python service layer for reading status, triggering manual syncs, testing connectivity
  - `scripts/web/blueprints/archive.py`: Flask blueprint with `/archive`, `/archive/sync`, `/archive/status`, `/archive/test` routes
  - `scripts/web/templates/archive.html`: archive status page with Sync Now / Test Connection actions
  - `scripts/web/static/css/archive.css`: styles for the archive page
  - `setup_usb.sh`: deploys and enables `nas_archive.service` and `nas_archive.timer`
  - `scripts/web/templates/base.html`: added Archive nav link
- NAS archive log viewer and sync history:
  - `scripts/nas_archive.sh`: tees all output to `$GADGET_DIR/logs/nas_archive_last.log`; tracks `bytes_transferred` and `duration_seconds`; `append_history()` prepends JSON run records to `nas_archive_history.json` (max 100 entries)
  - `scripts/web/services/archive_service.py`: added `get_last_log()` and `get_history()` functions
  - `scripts/web/blueprints/archive.py`: added `/archive/log` and `/archive/history` JSON endpoints
  - `scripts/web/templates/archive.html`: log viewer (scrollable `<pre>`) and history table with formatted timestamps, size, and duration
  - `scripts/web/static/css/archive.css`: styles for log viewer, history table, status badges
