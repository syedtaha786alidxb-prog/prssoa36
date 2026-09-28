#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Harbor Desk ERP — shared path/name definitions for one "site" (one tenant).
# Every other deploy script sources this file first. It reads the site's
# short name from the HD_SITE environment variable and derives everything
# else from it, so multiple independent sites can live on the same server
# without ever touching each other's code, database, port, or systemd unit.
#
#   HD_SITE=acme bash deploy/install.sh acme.example.com you@example.com
#
# Layout on the server for a site called "acme":
#   /opt/harbor-desk-acme/
#     app/        <- current release (code only — replaced on every update)
#     app/harbor-desk.db  <- the live SQLite database (NEVER touched by install.sh)
#     backups/    <- timestamped .db backups (backup-now.sh writes here)
#     port.txt    <- the port permanently assigned to this site (chosen once)
# ---------------------------------------------------------------------------
set -e
if [ -z "$HD_SITE" ]; then
  echo "[X] HD_SITE environment variable is not set (e.g. HD_SITE=acme). Aborting." >&2
  exit 1
fi

SITE="$HD_SITE"
BASE="/opt/harbor-desk-$SITE"
APP="$BASE/app"
DB="$APP/harbor-desk.db"
DIR="$BASE/backups"      # backup-now.sh / the Backup .bat read this
PORT_FILE="$BASE/port.txt"
SERVICE="harbor-desk-$SITE"
