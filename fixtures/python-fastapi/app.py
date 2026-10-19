"""FastAPI fixture for vps-setup-one-shot: Postgres through DATABASE_URL (psycopg 3).

Health contract: GET /api/health answers 200 {"status":"ok","db":"ok"} when the app and its
database work, 503 {"status":"error","db":"error"} otherwise, with no error details.
"""

import logging
import os
import socket
import time
from contextlib import asynccontextmanager

import psycopg
import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse

log = logging.getLogger("uvicorn.error")
DATABASE_URL = os.environ.get("DATABASE_URL", "")


def connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def migrate_or_exit(attempts=10, delay=3):
    # Mirrors starter/lib/db.ts: the database may still be booting, so retry briefly, then
    # fail the start so the container restarts instead of serving without a schema.
    for attempt in range(1, attempts + 1):
        try:
            with connect() as conn:
                conn.execute(
                    "create table if not exists hits ("
                    " id bigint generated always as identity primary key,"
                    " created_at timestamptz not null default now())"
                )
            log.info("db: schema ready")
            return
        except psycopg.Error as err:
            log.error("db: migrate attempt %d/%d failed: %s", attempt, attempts, err)
            time.sleep(delay)
    raise SystemExit(1)


@asynccontextmanager
async def lifespan(_app):
    migrate_or_exit()
    yield


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/", response_class=PlainTextResponse)
def index():
    return "python-fastapi fixture for vps-setup-one-shot\n"


@app.get("/api/health")
def health():
    try:
        with connect() as conn:
            conn.execute("select 1 from hits limit 1")  # the schema exists, not just a connection
        return {"status": "ok", "db": "ok"}
    except psycopg.Error as err:
        log.error("health: db check failed: %s", err)
        return JSONResponse({"status": "error", "db": "error"}, status_code=503)


def dual_stack_socket(port):
    # uvicorn --host :: listens on IPv6 only (asyncio sets IPV6_V6ONLY), so the proxy's IPv4
    # connection is refused. One socket with V6ONLY off takes both; Coolify's health check
    # calls localhost, which resolves to ::1 in many images.
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", port))
    sock.set_inheritable(True)
    return sock


if __name__ == "__main__":
    server = uvicorn.Server(uvicorn.Config(app))
    server.run(sockets=[dual_stack_socket(int(os.environ.get("PORT", "8000")))])
