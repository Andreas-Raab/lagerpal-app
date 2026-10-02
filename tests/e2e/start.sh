#!/usr/bin/env bash
# Startet die lokale Testumgebung: Postgres (Port 54329) mit dem Schema aus dem
# Repo + Testdaten, PostgREST (Port 54330) und den Test-Server (Port 54331).
# Nur für Tests in einem Entwicklungs-Container gedacht.
set -euo pipefail
cd "$(dirname "$0")/../.."
PG=/usr/lib/postgresql/16/bin; D=/var/tmp/lp-pg; P="psql -h /tmp -p 54329 -U postgres -v ON_ERROR_STOP=1 -q"
if ! $P -c 'select 1' >/dev/null 2>&1; then
  mkdir -p $D && chown postgres $D
  [ -d $D/data ] || su postgres -c "$PG/initdb -D $D/data -A trust -E UTF8 --locale=C.UTF-8" >/dev/null
  su postgres -c "$PG/pg_ctl -D $D/data -o '-p 54329 -k /tmp' -l $D/log start" >/dev/null; sleep 2
fi
$P -c "drop database if exists lp with (force)" -c "create database lp"
$P -d lp -f tests/sql/00_supabase_stub.sql
$P -d lp -f supabase/00_KOMPLETT_neu_aufsetzen.sql 2>&1 | grep -v NOTICE || true
for f in "$@"; do $P -d lp -f "$f" 2>&1 | grep -v NOTICE || true; done
$P -d lp -f tests/sql/01_testdaten.sql
$P -d lp -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if; end \$\$;" \
          -c "grant anon, authenticated, service_role to authenticator"
stopp() { [ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null || true; }
stopp /var/tmp/lp-e2e/postgrest.pid
cat > /var/tmp/lp-e2e/postgrest.conf <<CONF
db-uri = "postgres://authenticator@/lp?host=/tmp&port=54329"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "lokales-test-geheimnis-mindestens-32-zeichen"
server-port = 54330
CONF
nohup /var/tmp/postgrest /var/tmp/lp-e2e/postgrest.conf > /var/tmp/lp-e2e/postgrest.log 2>&1 &
echo $! > /var/tmp/lp-e2e/postgrest.pid
stopp /var/tmp/lp-e2e/server.pid
nohup node tests/e2e/server.js > /var/tmp/lp-e2e/server.log 2>&1 &
echo $! > /var/tmp/lp-e2e/server.pid
sleep 2
curl -sf http://localhost:54331/rest/v1/ >/dev/null && echo "Testumgebung läuft: http://localhost:54331/index.html"
