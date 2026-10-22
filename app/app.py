"""Small Flask app used to demonstrate the CI/CD pipeline."""
import os
import pathlib

import pymysql
from flask import Flask, jsonify, render_template_string

app = Flask(__name__)

PAGE = """
<!doctype html>
<title>AWS Proj-5</title>
<h1>AWS Proj-5 CI/CD demo</h1>
<p>Version: <code>{{ version }}</code></p>
<h2>Messages from RDS</h2>
{% if rows is none %}
  <p><strong>Database unavailable.</strong></p>
{% else %}
  <ul>{% for r in rows %}<li>{{ r.body }} <small>({{ r.created_at }})</small></li>{% endfor %}</ul>
{% endif %}
"""


def _version():
    path = pathlib.Path(__file__).with_name("VERSION")
    return path.read_text().strip() if path.exists() else "dev"


def get_conn():
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        connect_timeout=3,
        cursorclass=pymysql.cursors.DictCursor,
    )


@app.get("/health")
def health():
    return jsonify(status="ok", version=_version())


@app.get("/db-check")
def db_check():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1 AS ok")
            cur.fetchone()
        return jsonify(database="up")
    except Exception as exc:  # report any connectivity problem as 503
        return jsonify(database="down", error=type(exc).__name__), 503


@app.get("/")
def index():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, body, created_at FROM messages ORDER BY id DESC LIMIT 10")
            rows = cur.fetchall()
    except Exception:
        rows = None
    return render_template_string(PAGE, rows=rows, version=_version())
