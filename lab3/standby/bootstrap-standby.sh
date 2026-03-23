#!/bin/bash
set -e
umask 077

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
  exec gosu postgres "$0" "$@"
fi

chmod 0700 "$PGDATA"

if [ -f "$PGDATA/PG_VERSION" ] && [ -f "$PGDATA/standby.signal" ]; then
  echo "Existing standby data found, starting PostgreSQL..."
else
  echo "Waiting for primary to become available..."

  until PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
      -h "$PRIMARY_HOST" \
      -p "$PRIMARY_PORT" \
      -U "$REPLICATION_USER" \
      -D "$PGDATA" \
      -Fp -Xs -P -R
  do
    echo "Primary is not ready yet, retrying in 3 seconds..."
    rm -rf "${PGDATA:?}"/*
    sleep 3
  done

  echo "Base backup completed."
fi

chmod 0700 "$PGDATA"

if [ -f "$PGDATA/postgresql.auto.conf" ]; then
  sed -i '/^config_file[[:space:]]*=/d' "$PGDATA/postgresql.auto.conf"
fi

exec postgres -D "$PGDATA" -c "config_file=/etc/postgresql/postgresql.conf"
