#!/usr/bin/env bash
# The demonstration store against real databases through dot-sql's gateway: SQLite always,
# PostgreSQL and MariaDB when DOT_SQL_PG_DSN / DOT_SQL_MYSQL_DSN are set (see dot-sql/tools/test_live.sh).
here="$(cd "$(dirname "$0")/.." && pwd)"
exec "$here/addons/dot_sql/../../../dot-sql/tools/test_live.sh" "$here" res://examples/record_live.tscn
