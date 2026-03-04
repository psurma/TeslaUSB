"""Blueprint for NAS archive status and control."""

from flask import Blueprint, render_template, jsonify, request

from utils import get_base_context
from services.archive_service import get_archive_status, trigger_sync, test_nas_connection

archive_bp = Blueprint('archive', __name__, url_prefix='/archive')


@archive_bp.route("/")
def archive_status():
    """NAS archive status page."""
    ctx = get_base_context()
    status = get_archive_status()
    return render_template(
        'archive.html',
        page='archive',
        **ctx,
        archive=status,
    )


@archive_bp.route("/sync", methods=["POST"])
def sync_now():
    """Trigger a manual NAS sync. Returns JSON."""
    result = trigger_sync()
    return jsonify(result)


@archive_bp.route("/status")
def status_api():
    """JSON status endpoint for AJAX polling."""
    return jsonify(get_archive_status())


@archive_bp.route("/test")
def test_connection():
    """Test NAS connectivity. Returns JSON."""
    result = test_nas_connection()
    return jsonify(result)
