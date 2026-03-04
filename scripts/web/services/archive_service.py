#!/usr/bin/env python3
"""
NAS Archive Service for TeslaUSB.

Provides status and control functions for NAS archiving.
"""

import json
import logging
import os
import subprocess
import tempfile

logger = logging.getLogger(__name__)

STATUS_FILE = "/run/teslausb/nas_archive_status.json"


def _repo_root():
    """Return the repo root directory (two levels above services/)."""
    services_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(os.path.dirname(services_dir)))


def _logs_dir():
    """Return the persistent logs directory."""
    try:
        from config import GADGET_DIR
        return os.path.join(GADGET_DIR, 'logs')
    except Exception:
        return os.path.join(_repo_root(), 'logs')


def get_nas_config():
    """Read NAS archive config from config.yaml."""
    try:
        import yaml
        import os as _os
        config_yaml = _os.path.join(_repo_root(), 'config.yaml')
        with open(config_yaml, 'r') as f:
            cfg = yaml.safe_load(f)
        nas = cfg.get('nas_archive', {})
        return {
            'enabled': nas.get('enabled', False),
            'home_ssid': nas.get('home_ssid', ''),
            'smb_host': nas.get('smb_host', ''),
            'smb_share': nas.get('smb_share', ''),
            'smb_user': nas.get('smb_user', ''),
            'smb_password': nas.get('smb_password', ''),
            'smb_version': nas.get('smb_version', '2.0'),
            'delete_after_archive': nas.get('delete_after_archive', False),
        }
    except Exception as e:
        logger.error("Failed to read NAS config: %s", e)
        return {'enabled': False}


def get_archive_status():
    """
    Read the latest archive status from the status file written by nas_archive.sh.

    Returns a dict with keys:
      enabled, status, message, last_sync, files_synced, bytes_transferred, last_error, config
    """
    config = get_nas_config()

    default = {
        'enabled': config.get('enabled', False),
        'status': 'unknown',
        'message': 'No archive run yet',
        'last_sync': None,
        'files_synced': 0,
        'bytes_transferred': 0,
        'last_error': '',
        'config': config,
    }

    if not os.path.exists(STATUS_FILE):
        return default

    try:
        with open(STATUS_FILE, 'r') as f:
            data = json.load(f)
        data['enabled'] = config.get('enabled', False)
        data.setdefault('bytes_transferred', 0)
        data['config'] = config
        return data
    except Exception as e:
        logger.warning("Failed to read archive status file: %s", e)
        return default


def get_last_log():
    """
    Read the last rsync log file.

    Returns a dict with 'content' (str) and 'path' (str).
    """
    log_file = os.path.join(_logs_dir(), 'nas_archive_last.log')
    if not os.path.exists(log_file):
        return {'content': None, 'path': log_file}
    try:
        with open(log_file, 'r', errors='replace') as f:
            content = f.read()
        return {'content': content, 'path': log_file}
    except Exception as e:
        logger.warning("Failed to read archive log: %s", e)
        return {'content': None, 'path': log_file, 'error': str(e)}


def get_history():
    """
    Read the archive run history.

    Returns a list of dicts, newest first:
      timestamp, status, files_synced, bytes_transferred, duration_seconds, ssid, error
    """
    history_file = os.path.join(_logs_dir(), 'nas_archive_history.json')
    if not os.path.exists(history_file):
        return []
    try:
        with open(history_file, 'r') as f:
            return json.load(f)
    except Exception as e:
        logger.warning("Failed to read archive history: %s", e)
        return []


def trigger_sync():
    """
    Trigger a manual NAS archive sync by running nas_archive.sh in the background.

    Returns a dict with 'started' boolean and optional 'error' string.
    """
    try:
        from config import GADGET_DIR
        script = os.path.join(GADGET_DIR, 'scripts', 'nas_archive.sh')

        if not os.path.exists(script):
            return {'started': False, 'error': f'Archive script not found: {script}'}

        # Run non-blocking — fire and forget
        subprocess.Popen(
            ['/bin/bash', script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        return {'started': True}
    except Exception as e:
        logger.error("Failed to trigger NAS sync: %s", e)
        return {'started': False, 'error': str(e)}


def test_nas_connection():
    """
    Test NAS connectivity by attempting a brief CIFS mount.

    Returns a dict with 'reachable' boolean and optional 'error' string.
    """
    config = get_nas_config()

    if not config.get('enabled'):
        return {'reachable': False, 'error': 'NAS archiving is disabled'}

    host = config.get('smb_host', '')
    if not host:
        return {'reachable': False, 'error': 'No SMB host configured'}

    try:
        # Quick ping check first (fast fail)
        ping = subprocess.run(
            ['ping', '-c', '1', '-W', '2', host],
            capture_output=True,
            timeout=5,
            check=False,
        )
        if ping.returncode != 0:
            return {'reachable': False, 'error': f'Cannot reach host {host}'}

        share = config.get('smb_share', '')
        user = config.get('smb_user', '')
        password = config.get('smb_password', '')
        version = config.get('smb_version', '2.0')

        test_mount = tempfile.mkdtemp(prefix='teslausb_nas_test_')

        try:
            mount_opts = f'vers={version},username={user}'
            if password:
                mount_opts += f',password={password}'
            mount_opts += ',noserverino'

            result = subprocess.run(
                ['nsenter', '--mount=/proc/1/ns/mnt', '--',
                 'mount', '-t', 'cifs',
                 f'//{host}/{share}', test_mount,
                 '-o', mount_opts],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )

            if result.returncode == 0:
                subprocess.run(
                    ['nsenter', '--mount=/proc/1/ns/mnt', '--',
                     'umount', test_mount],
                    capture_output=True,
                    timeout=5,
                    check=False,
                )
                return {'reachable': True}
            else:
                err = result.stderr.strip() or result.stdout.strip()
                return {'reachable': False, 'error': err}
        finally:
            try:
                os.rmdir(test_mount)
            except OSError:
                pass

    except subprocess.TimeoutExpired:
        return {'reachable': False, 'error': 'Connection timed out'}
    except Exception as e:
        logger.error("NAS connection test failed: %s", e)
        return {'reachable': False, 'error': str(e)}
