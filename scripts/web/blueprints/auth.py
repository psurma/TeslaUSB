"""Blueprint for web UI authentication."""

from flask import Blueprint, render_template, request, redirect, url_for, session, flash

from config import WEB_PIN

auth_bp = Blueprint('auth', __name__)


@auth_bp.route('/login', methods=['GET', 'POST'])
def login():
    """PIN login page."""
    if not WEB_PIN:
        return redirect(url_for('mode_control.index'))
    if session.get('authenticated'):
        return redirect(url_for('mode_control.index'))
    if request.method == 'POST':
        pin = request.form.get('pin', '')
        if pin == WEB_PIN:
            session['authenticated'] = True
            next_url = request.args.get('next') or url_for('mode_control.index')
            return redirect(next_url)
        flash('Incorrect PIN', 'error')
    return render_template('login.html')


@auth_bp.route('/logout', methods=['POST'])
def logout():
    """Clear authentication session."""
    session.pop('authenticated', None)
    return redirect(url_for('auth.login'))
