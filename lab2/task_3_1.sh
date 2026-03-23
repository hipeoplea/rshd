#!/usr/bin/env bash

set -euo pipefail

export PGDATA=$HOME/ihv13
export PGPORT=9571
export DBUSER=chousik
export BASE_BACKUP_ROOT=$HOME/backup_dir
export NEW_TABLESPACE_ROOT=$HOME/restored_tablespaces

# Проверка состояния до сбоя
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select now();"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "\l"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select oid, spcname, pg_tablespace_location(oid) from pg_tablespace where spcname not in ('pg_default','pg_global');"

# Симуляция сбоя
rm -rf "$PGDATA/pg_wal"

# Пока сервер не перезапущен, он может отвечать
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select now();" || true

# После рестарта запуск должен завершиться ошибкой
pg_ctl -D "$PGDATA" restart || true
tail -n 50 "$PGDATA/server.log" || true

# Полностью останавливаем поврежденный кластер
pg_ctl -D "$PGDATA" stop -m immediate || true

# Ищем последнюю полную резервную копию
LATEST_BACKUP="$(find "$BASE_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | LC_ALL=C sort | tail -n 1)"
echo "$LATEST_BACKUP"
ls -lah "$LATEST_BACKUP"

# Сохраняем поврежденный каталог и создаем новый PGDATA
mv "$PGDATA" "${PGDATA}_broken_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PGDATA"
mkdir -p "$PGDATA/pg_wal"
mkdir -p "$NEW_TABLESPACE_ROOT"
chmod 700 "$PGDATA"
chmod 700 "$PGDATA/pg_wal"
chmod 700 "$NEW_TABLESPACE_ROOT"

# Восстанавливаем основной каталог кластера из последней полной копии
tar -xf "$LATEST_BACKUP/base.tar" -C "$PGDATA"

# Дополнительные tablespace переносим в новый каталог
for tar_file in "$LATEST_BACKUP"/*.tar; do
  [ -e "$tar_file" ] || continue
  tar_name="$(basename "$tar_file")"
  if [ "$tar_name" = "base.tar" ] || [ "$tar_name" = "pg_wal.tar" ]; then
    continue
  fi

  ts_oid="${tar_name%.tar}"
  new_ts_dir="$NEW_TABLESPACE_ROOT/$ts_oid"

  mkdir -p "$new_ts_dir"
  rm -f "$PGDATA/pg_tblspc/$ts_oid"
  ln -s "$new_ts_dir" "$PGDATA/pg_tblspc/$ts_oid"
  tar -xf "$tar_file" -C "$new_ts_dir"
done

# Подготавливаем восстановление WAL с резервного узла
touch "$PGDATA/postgresql.auto.conf"
sed -i '' '/^restore_command = /d' "$PGDATA/postgresql.auto.conf"
sed -i '' '/^recovery_target_timeline = /d' "$PGDATA/postgresql.auto.conf"
cat >> "$PGDATA/postgresql.auto.conf" <<'EOF'
restore_command = 'scp postgres0@pg133:/var/db/postgres0/backup_dir/wal/%f %p'
recovery_target_timeline = 'latest'
EOF

ssh-keyscan -H pg133 >> ~/.ssh/known_hosts 2>/dev/null || true
touch "$PGDATA/recovery.signal"

# Запускаем восстановленный кластер
pg_ctl -D "$PGDATA" -l "$PGDATA/server.log" start || true
tail -n 50 "$PGDATA/server.log" || true

# Проверка состояния после восстановления
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select pg_is_in_recovery();"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select now();"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "\l"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "\dt"
psql -h localhost -p "$PGPORT" -U "$DBUSER" -d postgres -c "select oid, spcname, pg_tablespace_location(oid) from pg_tablespace where spcname not in ('pg_default','pg_global');"
