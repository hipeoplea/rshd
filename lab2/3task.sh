#!/usr/bin/env bash

export PGDATA=$HOME/ihv13
export PGENCODE=KOI8-R
export PGLOCALE=ru_RU.KOI8-R
export PGUSERNAME=postgres8
export NEW_TABLESPACE_ROOT=restored_tablespaces
export BASE_BACKUP_ROOT=backup_dir

PGPORT="9571"
PGUSER="chousik"

set -euo pipefail

# Симуляция сбоя: удаляем каталог WAL
rm -rf "$PGDATA/pg_wal"

# Проверка, что пока запущенный сервер еще может отвечать
psql -h "$PGDATA" -p 9571 -U chousik -d postgres -c "select now();" || true

# После рестарта сервер уже не поднимется
pg_ctl -D "$PGDATA" restart || true
tail -n 50 "$PGDATA/server.log" || true

# Останавливаем поврежденный кластер
pg_ctl -D "$PGDATA" stop -m immediate || true

# Находим последнюю полную копию
LATEST_BACKUP="$(find "$HOME/backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | LC_ALL=C sort | tail -n 1)"

# Сохраняем старый PGDATA и готовим новый каталог
mv "$PGDATA" "${PGDATA}_broken_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PGDATA"
mkdir -p "$PGDATA/pg_wal"
mkdir -p "$NEW_TABLESPACE_ROOT"

# Восстанавливаем основной каталог кластера
tar -xf "$LATEST_BACKUP/base.tar" -C "$PGDATA"

# Если в копии есть pg_wal.tar, распаковываем его тоже
if [ -f "$LATEST_BACKUP/pg_wal.tar" ]; then
  tar -xf "$LATEST_BACKUP/pg_wal.tar" -C "$PGDATA/pg_wal"
fi

# Дополнительные табличные пространства переносим в новый каталог
for tar_file in "$LATEST_BACKUP"/*.tar; do
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

chmod 700 "$PGDATA"

# Настраиваем восстановление WAL с резервного узла
cat >> "$PGDATA/postgresql.auto.conf" <<EOF
restore_command = 'scp ${REMOTE_WAL_HOST}:${REMOTE_WAL_DIR}/%f %p'
recovery_target_timeline = 'latest'
EOF

touch "$PGDATA/recovery.signal"

# Запускаем восстановленный кластер
pg_ctl -D "$PGDATA" -l "$PGDATA/server.log" start

# Проверяем, что сервер поднялся и данные доступны
psql -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d postgres -c "select now();"
psql -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d postgres -c "select oid, spcname, pg_tablespace_location(oid) from pg_tablespace where spcname not in ('pg_default','pg_global');"
psql -h "$PGDATA" -p "$PGPORT" -U "$PGUSER" -d postgres -c "\l"
