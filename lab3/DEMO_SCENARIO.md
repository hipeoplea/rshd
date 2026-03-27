# Сценарий демонстрации PostgreSQL primary/standby

Все команды ниже предполагают запуск из корня проекта:

```bash
cd /Users/hipeoplea/rshd/lab3
```

Аутентификация:
- локальные подключения настроены без `trust`
- для всех вызовов `psql` через `docker exec` ниже используется `-e PGPASSWORD=postgres`
- для репликации резервный узел использует отдельного пользователя `replicator`

Поднять стенд:

```bash
docker compose up -d --build
docker compose ps
```

Проверить, что репликация активна:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, client_addr, state, sync_state from pg_stat_replication;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "show transaction_read_only;"
```

Ожидаемо:
- на `primary` видно подключение реплики в состоянии `streaming`
- на `standby` `pg_is_in_recovery = t`
- на `standby` `transaction_read_only = on`

## Подключение клиентов

Откройте 3 терминала.

Терминал 1, клиент записи на основном сервере:

```bash
docker exec -e PGAPPNAME=client_rw_1 -e PGPASSWORD=postgres -it primary psql -U postgres -d appdb
```

Терминал 2, второй клиент записи на основном сервере:

```bash
docker exec -e PGAPPNAME=client_rw_2 -e PGPASSWORD=postgres -it primary psql -U postgres -d appdb
```

Терминал 3, клиент чтения на резервном сервере:

```bash
docker exec -e PGAPPNAME=client_ro_1 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
```

В отдельном терминале можно показать активные клиентские подключения:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pid, application_name, state, backend_type from pg_stat_activity where datname = 'appdb' order by pid;"
```

## Этап 1. Демонстрация наполнения базы и репликации

Показать исходные таблицы и данные на основном сервере:

```sql
\dt
select * from test1 order by id;
select * from test2 order by id;
show transaction_read_only;
```

Показать на резервном сервере режим только чтения:

```sql
select * from test1 order by id;
select * from test2 order by id;
show transaction_read_only;
```

В `client_rw_1` выполнить первую транзакцию на основном сервере:

```sql
begin;
insert into test1(value) values ('phase1_row_1'), ('phase1_row_2');
insert into test2(amount) values (100), (200);
commit;
```

В `client_rw_2` выполнить вторую транзакцию на основном сервере:

```sql
begin;
update test1 set value = value || '_upd' where id = 1;
update test2 set amount = amount + 5 where id = 1;
commit;
```

Показать новые данные на основном сервере:

```sql
select * from test1 order by id;
select * from test2 order by id;
```

Показать, что новые данные появились на резервном сервере:

```sql
select * from test1 order by id;
select * from test2 order by id;
```

Дополнительная проверка репликации:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn from pg_stat_replication;"
```

## Этап 2. Симуляция и обработка сбоя

### 2.1 Подготовка

Показать, что клиенты подключены и основной сервер работает в режиме чтение/запись:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pid, application_name, state from pg_stat_activity where datname = 'appdb' order by pid;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "show transaction_read_only;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "show transaction_read_only;"
```

При желании перед сбоем выполните ещё одну короткую транзакцию на `primary`:

```sql
begin;
insert into test1(value) values ('before_failover');
insert into test2(amount) values (999);
commit;
```

### 2.2 Сбой

В контейнерной версии стенда аналог `Power Off` узла:

```bash
docker update --restart=no primary
docker kill -s SIGKILL primary
docker compose ps
```

Что показать после сбоя:
- в уже открытых `psql`-сессиях на `primary` любая следующая команда завершается ошибкой разрыва соединения
- `standby` остаётся доступным на чтение

### 2.3 Обработка

Найти релевантные сообщения в логах:

```bash
docker logs primary 2>&1 | tail -n 50
docker logs standby 2>&1 | tail -n 100
docker logs standby 2>&1 | rg -n "stream|promot|recovery|ready|connect|wal"
```

Обычно в логах `standby` стоит показать сообщения вида:
- потеря связи с primary или ошибка чтения WAL stream
- переход к promote
- завершение recovery
- готовность принимать подключения

Выполнить failover на резервный сервер:

```bash
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_promote();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "show transaction_read_only;"
```

Ожидаемо:
- до `pg_promote()` значение `pg_is_in_recovery = t`
- после `pg_promote()` значение `pg_is_in_recovery = f`
- после failover `transaction_read_only = off`

Открыть новые клиентские подключения уже к бывшему `standby`:

```bash
docker exec -e PGAPPNAME=client_rw_after_failover_1 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
docker exec -e PGAPPNAME=client_rw_after_failover_2 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
```

Показать чтение/запись на новом основном сервере:

```sql
begin;
insert into test1(value) values ('after_failover_1'), ('after_failover_2');
insert into test2(amount) values (1000), (2000);
commit;
```

```sql
begin;
update test1 set value = 'after_failover_updated' where id = 1;
update test2 set amount = amount + 1000 where id = 1;
commit;
```

Показать итоговые данные на новом основном сервере:

```sql
select * from test1 order by id;
select * from test2 order by id;
```

## Восстановление исходной конфигурации

Нужно:
- вернуть старый `primary` в строй
- накатить на него все изменения, сделанные после failover
- снова сделать его основным
- заново собрать `standby` уже от восстановленного `primary`

### 1. Актуализировать старый primary

Поднять возможность автоматического старта обратно:

```bash
docker update --restart=unless-stopped primary
```

Полностью переснять старый `primary` с текущего основного узла `standby`:

```bash
docker compose stop primary
rm -rf primary/data/*
mkdir -p primary/data
chmod 700 primary/data
docker compose run --rm --no-deps --entrypoint bash primary -lc '
  set -e
  mkdir -p /var/lib/postgresql/data
  chown -R postgres:postgres /var/lib/postgresql/data
  chmod 700 /var/lib/postgresql/data
  export PGPASSWORD=replpass
  gosu postgres pg_basebackup \
    -h standby \
    -p 5432 \
    -U replicator \
    -D /var/lib/postgresql/data \
    -Fp -Xs -P -R
'
docker compose up -d primary
```

Проверить, что старый `primary` поднялся как реплика и получил все изменения:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test1 order by id;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test2 order by id;"
```

### 2. Вернуть исходные роли

Остановить запись клиентов на текущий основной узел `standby`.

Остановить текущий основной узел и повысить старый `primary`:

```bash
docker compose stop standby
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_promote();"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "show transaction_read_only;"
```

Теперь заново создать `standby` уже от восстановленного `primary`:

```bash
rm -rf standby/data/*
mkdir -p standby/data
chmod 700 standby/data
docker compose up -d --build --force-recreate standby
```

### 3. Финальная проверка

Проверить, что исходная схема восстановлена:

```bash
docker compose ps
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, state, sync_state from pg_stat_replication;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "show transaction_read_only;"
```

Сделать финальную транзакцию на `primary`:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "begin; insert into test1(value) values ('final_check'); insert into test2(amount) values (7777); commit;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test1 order by id desc limit 5;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test2 order by id desc limit 5;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select * from test1 order by id desc limit 5;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select * from test2 order by id desc limit 5;"
```

## Короткая формулировка для защиты

Можно использовать такую формулировку:

> PostgreSQL развернут на двух узлах в режиме физической асинхронной потоковой репликации WAL. Основной сервер работает в режиме чтение/запись, резервный сервер в режиме hot standby только для чтения. При отказе основного узла выполнен failover на резервный сервер, после чего на нём продолжена работа в режиме чтение/запись. Далее старый основной узел был актуализирован с помощью нового base backup, после чего исходная конфигурация `primary -> standby` была восстановлена.

## Примечание

Для возврата в исходную конфигурацию здесь используется полный `pg_basebackup`. Это самый надёжный путь для текущего стенда. Более быстрый возврат через `pg_rewind` потребовал бы отдельной подготовки конфигурации.
