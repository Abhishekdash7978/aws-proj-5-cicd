import pytest

import app as app_module


class FakeCursor:
    def __init__(self, rows):
        self._rows = rows

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, args=None):
        pass

    def fetchall(self):
        return self._rows

    def fetchone(self):
        return self._rows[0] if self._rows else None


class FakeConn:
    def __init__(self, rows):
        self._rows = rows

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def cursor(self):
        return FakeCursor(self._rows)


def _db_down():
    raise ConnectionError("db down")


@pytest.fixture
def client():
    app_module.app.config.update(TESTING=True)
    return app_module.app.test_client()


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_index_lists_messages(client, monkeypatch):
    rows = [{"id": 1, "body": "Hello from RDS", "created_at": "2026-01-01"}]
    monkeypatch.setattr(app_module, "get_conn", lambda: FakeConn(rows))
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Hello from RDS" in resp.data


def test_index_handles_db_outage(client, monkeypatch):
    monkeypatch.setattr(app_module, "get_conn", _db_down)
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Database unavailable" in resp.data


def test_db_check_up(client, monkeypatch):
    monkeypatch.setattr(app_module, "get_conn", lambda: FakeConn([{"ok": 1}]))
    assert client.get("/db-check").get_json() == {"database": "up"}


def test_db_check_down(client, monkeypatch):
    monkeypatch.setattr(app_module, "get_conn", _db_down)
    resp = client.get("/db-check")
    assert resp.status_code == 503
    assert resp.get_json()["database"] == "down"
