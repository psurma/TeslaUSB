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
