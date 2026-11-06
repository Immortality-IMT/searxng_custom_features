# SPDX-License-Identifier: AGPL-3.0-or-later
"""Result collector + cache (steps 1 and 2).

* record()        store every live search: query, URLs/positions and a complete
                  page snapshot (results, infoboxes, answers, suggestions, ...)
* lookup()        return a ready ResultContainer built from the newest good snapshot
* refresh_async() re-run the query in the background, rate limited, and record it

Nothing here may break a search: every public function catches its own errors.
"""

import copy
import hashlib
import json
import logging
import os
import pickle
import sqlite3
import threading
import time
import unicodedata
import zlib
from collections.abc import Mapping
from urllib.parse import urlparse

# <repo root>/cache/ is git-ignored and created by the SearXNG installer.
# Override with the SEARXNG_COLLECTOR_DB environment variable.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DB_PATH = os.environ.get("SEARXNG_COLLECTOR_DB", os.path.join(_REPO_ROOT, "cache", "collector.db"))

SNAPSHOT_SCHEMA = 1          # bump to invalidate all stored snapshots
KEEP_SNAPSHOTS = 5           # newest snapshots kept per query (docs/hits are kept forever)
MIN_GAP = 600                # seconds between background refreshes of the SAME query
MAX_REFRESH_PER_MIN = 6      # background refreshes started per minute, all queries together
MAX_REFRESH_THREADS = 2      # concurrent background refreshes per uwsgi process
GOOD_RATIO = 0.7             # serve only snapshots with >= 70% of the best result count seen

log = logging.getLogger("collector")
_local = threading.local()
_refresh_slots = threading.BoundedSemaphore(MAX_REFRESH_THREADS)

SCHEMA = """
CREATE TABLE IF NOT EXISTS query (
  id INTEGER PRIMARY KEY,
  key TEXT UNIQUE NOT NULL,
  q_norm TEXT, lang TEXT, pageno INT, categories TEXT,
  time_range TEXT, safesearch INT,
  first_seen INT, last_seen INT, run_count INT DEFAULT 1
);
CREATE TABLE IF NOT EXISTS run (
  id INTEGER PRIMARY KEY,
  query_id INT NOT NULL REFERENCES query(id),
  ts INT, n_results INT
);
CREATE TABLE IF NOT EXISTS doc (
  id INTEGER PRIMARY KEY,
  url_norm TEXT UNIQUE NOT NULL,
  url TEXT, title TEXT, content TEXT,
  first_seen INT, last_seen INT, seen_count INT DEFAULT 1
);
CREATE TABLE IF NOT EXISTS hit (
  run_id INT NOT NULL REFERENCES run(id),
  doc_id INT NOT NULL REFERENCES doc(id),
  position INT, score REAL, engines TEXT,
  PRIMARY KEY (run_id, doc_id)
);
CREATE INDEX IF NOT EXISTS hit_doc ON hit(doc_id);

-- step 2: complete page snapshots (zlib-compressed pickle of the container state)
CREATE TABLE IF NOT EXISTS snapshot (
  id INTEGER PRIMARY KEY,
  query_id INT NOT NULL REFERENCES query(id),
  run_id INT, ts INT,
  n_results INT, n_engines INT,
  version TEXT,
  payload BLOB
);
CREATE INDEX IF NOT EXISTS snap_q ON snapshot(query_id, ts DESC);

-- step 2: one row per query, doubles as the refresh cooldown / claim
CREATE TABLE IF NOT EXISTS refresh (
  key TEXT PRIMARY KEY,
  started_at INT
);
"""


# --------------------------------------------------------------------------- helpers

def _conn():
    c = getattr(_local, "c", None)
    if c is None:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        c = sqlite3.connect(DB_PATH, timeout=5)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.executescript(SCHEMA)
        _local.c = c
    return c


def _version():
    from searx.version import VERSION_STRING  # pylint: disable=import-outside-toplevel
    return f"{VERSION_STRING}|{SNAPSHOT_SCHEMA}"


def _get(r, name, default=None):
    """Result items are objects/dict subclasses in newer SearXNG, plain dicts in older."""
    v = getattr(r, name, None)
    if v is None and isinstance(r, Mapping):
        v = r.get(name)
    return default if v is None else v


def _norm_query(q):
    return " ".join(unicodedata.normalize("NFKC", q).split())


def make_key(sq):
    payload = {
        "q": _norm_query(sq.query),
        "pageno": sq.pageno,
        "lang": sq.lang,
        "safesearch": sq.safesearch,
        "time_range": sq.time_range,
        "categories": sorted(sq.categories),
        "engines": sorted(f"{e.name}|{e.category}" for e in sq.engineref_list),
    }
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest()


def norm_url(url):
    """Roughly what compare_urls ignores: scheme, www., trailing slash, fragment."""
    p = urlparse(url)
    host = (p.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host + p.path.rstrip("/") + ("?" + p.query if p.query else "")


# --------------------------------------------------------------------------- record

def _snapshot_blob(rc, results):
    return zlib.compress(
        pickle.dumps(
            {
                "results": results,
                "infoboxes": rc.infoboxes,
                "suggestions": set(rc.suggestions),
                "answers": rc.answers,
                "corrections": set(rc.corrections),
                "engine_data": {k: dict(v) for k, v in rc.engine_data.items()},
                "paging": rc.paging,
                "unresponsive_engines": set(rc.unresponsive_engines),
                "timings": list(rc.timings),
            },
            protocol=pickle.HIGHEST_PROTOCOL,
        )
    )


def record(sq, rc):
    """Store one finished search (docs, hits and a page snapshot). Never raises.

    Must be called BEFORE the webapp post-processes the results for HTML
    (highlighting mutates them), i.e. right after the search.
    """
    try:
        results = rc.get_ordered_results()
        rows = [r for r in results if _get(r, "url")]
        if not rows:
            return
        now = int(time.time())
        key = make_key(sq)
        engines_seen = set()
        for r in rows:
            engines_seen.update(_get(r, "engines") or [])
        blob = _snapshot_blob(rc, results)

        db = _conn()
        with db:  # one transaction: readers see the old state or the new one
            db.execute(
                """INSERT INTO query(key,q_norm,lang,pageno,categories,time_range,safesearch,first_seen,last_seen)
                   VALUES(?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(key) DO UPDATE SET last_seen=excluded.last_seen, run_count=run_count+1""",
                (key, _norm_query(sq.query), sq.lang, sq.pageno, ",".join(sorted(sq.categories)),
                 sq.time_range, sq.safesearch, now, now),
            )
            qid = db.execute("SELECT id FROM query WHERE key=?", (key,)).fetchone()[0]
            run_id = db.execute(
                "INSERT INTO run(query_id,ts,n_results) VALUES(?,?,?)", (qid, now, len(rows))
            ).lastrowid
            for pos, r in enumerate(rows, 1):
                url = _get(r, "url")
                un = norm_url(url)
                db.execute(
                    """INSERT INTO doc(url_norm,url,title,content,first_seen,last_seen)
                       VALUES(?,?,?,?,?,?)
                       ON CONFLICT(url_norm) DO UPDATE SET
                         last_seen=excluded.last_seen, seen_count=seen_count+1,
                         content=CASE WHEN length(coalesce(excluded.content,'')) > length(coalesce(doc.content,''))
                                      THEN excluded.content ELSE doc.content END""",
                    (un, url, _get(r, "title"), _get(r, "content"), now, now),
                )
                did = db.execute("SELECT id FROM doc WHERE url_norm=?", (un,)).fetchone()[0]
                score = _get(r, "score")
                db.execute(
                    "INSERT OR IGNORE INTO hit(run_id,doc_id,position,score,engines) VALUES(?,?,?,?,?)",
                    (run_id, did, pos, float(score) if score is not None else None,
                     ",".join(sorted(_get(r, "engines") or []))),
                )
            db.execute(
                """INSERT INTO snapshot(query_id,run_id,ts,n_results,n_engines,version,payload)
                   VALUES(?,?,?,?,?,?,?)""",
                (qid, run_id, now, len(rows), len(engines_seen), _version(), blob),
            )
            db.execute(
                """DELETE FROM snapshot WHERE query_id=? AND id NOT IN
                   (SELECT id FROM snapshot WHERE query_id=? ORDER BY ts DESC, id DESC LIMIT ?)""",
                (qid, qid, KEEP_SNAPSHOTS),
            )
    except Exception:  # pylint: disable=broad-except
        log.exception("collector.record failed")


# --------------------------------------------------------------------------- lookup

def lookup(sq):
    """Return a ResultContainer rebuilt from the newest good snapshot, or None (= go live)."""
    try:
        if getattr(sq, "external_bang", None):
            return None
        db = _conn()
        ver = _version()
        row = db.execute(
            """SELECT s.payload FROM snapshot s JOIN query q ON q.id = s.query_id
               WHERE q.key = ? AND s.version = ?
                 AND s.n_results >= ? * (SELECT MAX(n_results) FROM snapshot
                                         WHERE query_id = q.id AND version = ?)
               ORDER BY s.ts DESC, s.id DESC LIMIT 1""",
            (make_key(sq), ver, GOOD_RATIO, ver),
        ).fetchone()
        if not row:
            return None
        return _build_container(pickle.loads(zlib.decompress(row[0])))  # nosec - local, trusted DB
    except Exception:  # pylint: disable=broad-except
        log.exception("collector.lookup failed, falling back to live search")
        return None


def _build_container(d):
    from searx.results import ResultContainer  # pylint: disable=import-outside-toplevel

    rc = ResultContainer()
    rc._main_results_sorted = d["results"]  # pylint: disable=protected-access
    rc.infoboxes = d["infoboxes"]
    rc.suggestions = d["suggestions"]
    rc.answers = d["answers"]
    rc.corrections = d["corrections"]
    for eng, data in d["engine_data"].items():
        rc.engine_data[eng].update(data)
    rc.paging = d["paging"]
    rc.unresponsive_engines = d["unresponsive_engines"]
    rc.timings = d["timings"]
    rc._closed = True  # pylint: disable=protected-access
    return rc


# --------------------------------------------------------------------------- refresh

def _claim(key):
    """True if this process may start a refresh for `key` now (per-query cooldown + global cap)."""
    now = int(time.time())
    db = _conn()
    with db:
        recent = db.execute("SELECT count(*) FROM refresh WHERE started_at > ?", (now - 60,)).fetchone()[0]
        if recent >= MAX_REFRESH_PER_MIN:
            return False
        cur = db.execute(
            """INSERT INTO refresh(key, started_at) VALUES(?, ?)
               ON CONFLICT(key) DO UPDATE SET started_at = excluded.started_at
               WHERE refresh.started_at < ?""",
            (key, now, now - MIN_GAP),
        )
        return cur.rowcount == 1


def refresh_async(sq, make_search):
    """Re-run `sq` in a background thread and record the result.

    `make_search(query)` must return a SearchWithPlugins; it is called here, in
    the request thread (it needs the Flask request context), only after the
    claim succeeded.  Never raises.
    """
    try:
        if not _refresh_slots.acquire(blocking=False):
            return
        started = False
        try:
            if not _claim(make_key(sq)):
                return
            sq_copy = copy.copy(sq)
            search = make_search(sq_copy)

            def _run():
                try:
                    rc = search.search()
                    record(sq_copy, rc)
                except Exception:  # pylint: disable=broad-except
                    log.exception("collector background refresh failed")
                finally:
                    _refresh_slots.release()

            threading.Thread(target=_run, name="collector-refresh", daemon=True).start()
            started = True
        finally:
            if not started:
                _refresh_slots.release()
    except Exception:  # pylint: disable=broad-except
        log.exception("collector.refresh_async failed")
