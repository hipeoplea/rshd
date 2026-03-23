	.bashrc

export PGDATA=$HOME/ihv13
export PGENCODE=KOI8-R
export PGLOCALE=ru_RU.KOI8-R
export PGUSERNAME=postgres8

	Рестарт

pg_ctl -D $PGDATA restart

	Копирование ssh-key

ssh-keygen -t rsa
ssh-copy-id -i ~/.ssh/id_rsa.pub postgres0@pg133

	Создание юзера

CREATE ROLE chousik WITH LOGIN REPLICATION PASSWORD 'admin';

	Добавить в авторизацию

local   replication    chousik                 trust

	Создать папку

ssh postgres0@pg133 "mkdir -p ~/backup_dir/wal"

	Архивация WAL

Добавь в postgresql.conf

wal_level = replica
archive_mode = on
archive_command = 'scp %p postgres0@pg133:backup_dir/wal/%f'
archive_timeout = 60

	Скрипт копирование

set -eu

DATATIME="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$HOME/backup_dir"
BACKUP_NAME="backup-${DATATIME}"

mkdir -p "$BACKUP_DIR"

PGPORT="9571"
PGUSER="chousik"
BACKUP_DEST="${BACKUP_DIR}/${BACKUP_NAME}"

# фулл физическая копия
pg_basebackup \
  -p "${PGPORT}" \
  -U "${PGUSER}" \
  -D "${BACKUP_DEST}" \
  -Fp \
  --checkpoint=fast

#Копирование бэкапа
scp -r "${BACKUP_DEST}" "postgres0@pg133:backup_dir/"

#Удаление локально
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -mtime +7 -exec rm -rf {} \;

#Удаление на удаленном
ssh postgres0@pg133 "find ~/backup_dir -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -mtime +30 -exec rm -rf {} \;"

	Создание автозапуска

Мы положили скрипт в /var/db/postgres8/best_backup.sh

Сначала сделаем его исполняемым

chmod +x /var/db/postgres8/best_backup.sh

Теперь добавим в `crontab -e` строчку

0 0 * 2 * /bin/sh /var/db/postgres8/best_backup.sh >> /var/db/postgres8/pg_backup.log 2>&1

	Проверим, что все вставилось

crontab -l

[postgres8@pg100 ~]$ crontab -l
0 0,12 * * * /bin/sh /var/db/postgres8/best_backup.sh >> /var/db/postgres8/pg_backup.log 2>&1

	Что бы не ждать 12 часов сделаем временно каждую минуту)

* * * * * /bin/sh /var/db/postgres8/pg_backup.sh >> /var/db/postgres8/pg_backup.log 2>&1

[фото3]