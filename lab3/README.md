# PostgreSQL Primary/Standby Demo

Проект демонстрирует:
- `primary` с чтением и записью
- `standby` в режиме потоковой репликации WAL
- аварийное отключение основного узла
- failover на резервный сервер
- сохранность данных и восстановление режима чтение/запись после переключения

## Что уже настроено

- два узла поднимаются через `docker compose`
- репликация строится штатными средствами PostgreSQL без дополнительных пакетов
- локальная аутентификация настроена без `trust`
- для команд `psql` ниже используется `PGPASSWORD=postgres`

## Чистый старт перед защитой

Если стенд уже использовался ранее, начните с нуля:

```bash
cd /Users/hipeoplea/rshd/lab3
docker compose down
rm -rf primary/data standby/data
mkdir -p primary/data standby/data
chmod 700 primary/data standby/data
docker compose up -d --build
docker compose ps
```

Ожидаемо:
- `primary` в статусе `healthy`
- `standby` в статусе `Up`

Быстрая проверка репликации:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, client_addr, state, sync_state from pg_stat_replication;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
```

Ожидаемо:
- на `primary` есть строка со `state = streaming`
- на `standby` `pg_is_in_recovery = t`
- на `standby` `transaction_read_only = on`

## Демонстрация на защите

Ниже сценарий ровно под пункты `2.1`, `2.2`, `2.3`.

### 2.1 Подготовка

Откройте 4 терминала.

Терминал 1, первый клиент на основном сервере:

```bash
docker exec -e PGAPPNAME=client_rw_1 -e PGPASSWORD=postgres -it primary psql -U postgres -d appdb
```

Терминал 2, второй клиент на основном сервере:

```bash
docker exec -e PGAPPNAME=client_rw_2 -e PGPASSWORD=postgres -it primary psql -U postgres -d appdb
```

Терминал 3, клиент на резервном сервере:

```bash
docker exec -e PGAPPNAME=client_ro_1 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
```

Терминал 4, мониторинг:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, state, backend_type from pg_stat_activity where datname = 'appdb' order by application_name, pid;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "show transaction_read_only;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "show transaction_read_only;"
```

В каждом `psql` выключите pager:

```sql
\pset pager off
```

В `client_rw_1` показать режим чтение/запись и текущее содержимое:

```sql
show transaction_read_only;
select * from test1 order by id;
```

В `client_rw_2` показать вторую таблицу:

```sql
show transaction_read_only;
select * from test2 order by id;
```

В `client_ro_1` показать, что резервный сервер только для чтения:

```sql
show transaction_read_only;
select * from test1 order by id;
select * from test2 order by id;
```

После этого выполните две короткие транзакции на `primary`.

В `client_rw_1`:

```sql
begin;
insert into test1(value) values ('before_failover_rw1');
commit;
select * from test1 order by id;
```

В `client_rw_2`:

```sql
begin;
insert into test2(amount) values (2025);
commit;
select * from test2 order by id;
```

Снова перейти в `client_ro_1` и показать, что новые строки уже пришли на резервный сервер:

```sql
select * from test1 order by id;
select * from test2 order by id;
```

Что проговариваете:
- на `primary` режим `transaction_read_only = off`
- на `standby` режим `transaction_read_only = on`
- новые данные с `primary` уже видны на резервном узле

### 2.2 Сбой

В отдельном терминале имитируйте `Power Off` основного узла:

```bash
docker update --restart=no primary
docker kill -s SIGKILL primary
docker compose ps
```

Что показать сразу после этого:
- в `client_rw_1` или `client_rw_2` любая следующая команда оборвёт соединение
- `client_ro_1` на бывшем `standby` продолжает отвечать

Для наглядности:

В одном из старых клиентов `primary`:

```sql
select now();
```

Ожидаемо: сессия завершается ошибкой из-за внезапного завершения `postmaster`.

В `client_ro_1`:

```sql
select now();
select * from test1 order by id;
```

Ожидаемо: резервный узел по-прежнему доступен на чтение.

### 2.3 Обработка

Сначала показать релевантные сообщения в логах.

Лог бывшего `primary`:

```bash
docker compose logs --tail=80 primary
```

Ищите строки вида:
- `terminating connection due to unexpected postmaster exit`

Лог бывшего `standby`:

```bash
docker compose logs --tail=80 standby
docker compose logs --tail=80 standby | rg -n "WAL|waiting for WAL|promote|recovery|ready"
```

Ищите строки вида:
- `could not receive data from WAL stream`
- `waiting for WAL to become available`
- `received promote request`
- `archive recovery complete`
- `database system is ready to accept connections`

Теперь выполнить failover:

```bash
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_promote();"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
```

Ожидаемо:
- до `pg_promote()` `pg_is_in_recovery = t`
- после `pg_promote()` `pg_is_in_recovery = f`
- после `pg_promote()` `transaction_read_only = off`

Откройте две новые клиентские сессии уже на бывшем `standby`:

```bash
docker exec -e PGAPPNAME=client_rw_after_failover_1 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
docker exec -e PGAPPNAME=client_rw_after_failover_2 -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
```

В обеих сессиях:

```sql
\pset pager off
show transaction_read_only;
```

Ожидаемо в обеих: `off`.

В `client_rw_after_failover_1`:

```sql
begin;
insert into test1(value) values ('after_failover_rw1');
commit;
select * from test1 order by id;
```

В `client_rw_after_failover_2`:

```sql
begin;
insert into test2(amount) values (3030);
commit;
select * from test2 order by id;
```

Дополнительно можно показать активные подключения уже на новом основном узле:

```bash
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select application_name, state, backend_type from pg_stat_activity where datname = 'appdb' order by application_name, pid;"
```

Что проговариваете:
- резервный сервер успешно переведён в основной
- данные, записанные до сбоя, сохранились
- после failover сервер снова принимает запись

### 2.4 Возврат к исходной конфигурации

Цель этого этапа:
- вернуть старый `primary` в работу
- перенести на него все изменения, сделанные после failover
- снова сделать его основным сервером
- заново поднять `standby` как реплику от восстановленного `primary`

Исходная ситуация перед началом этого этапа:
- контейнер `primary` остановлен после аварийного отключения
- контейнер `standby` уже был promoted и сейчас работает как основной сервер
- на `standby` уже есть новые строки `after_failover_rw1` и `3030`

#### Шаг 1. Вернуть старый `primary` и накатить на него изменения

Сначала вернуть политику рестарта, отключённую на этапе сбоя:

```bash
docker update --restart=unless-stopped primary
```

Теперь полностью переснять старый `primary` с текущего рабочего узла `standby`:

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

Проверка, что старый `primary` поднялся как актуальная реплика:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test1 order by id;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test2 order by id;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select application_name, state, sync_state from pg_stat_replication;"
```

Ожидаемо:
- на старом `primary` `pg_is_in_recovery = t`
- на старом `primary` `transaction_read_only = on`
- на старом `primary` уже видны строки `after_failover_rw1` и `3030`
- на текущем основном узле `standby` видна реплика в `streaming`

#### Шаг 2. Вернуть роли `primary` и `standby`

На этом шаге не выполняйте новые записи в базу.

Остановить текущий основной узел `standby` и повысить старый `primary`:

```bash
docker compose stop standby
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_promote();"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
```

Ожидаемо:
- после `pg_promote()` на `primary` `pg_is_in_recovery = f`
- после `pg_promote()` на `primary` `transaction_read_only = off`

#### Шаг 3. Заново собрать `standby` уже от восстановленного `primary`

Очистить датадир `standby` и поднять его заново:

```bash
rm -rf standby/data/*
mkdir -p standby/data
chmod 700 standby/data
docker compose up -d --build --force-recreate standby
```

Проверить, что исходная схема восстановлена:

```bash
docker compose ps
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, client_addr, state, sync_state from pg_stat_replication;"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "show transaction_read_only;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select pg_is_in_recovery(), current_setting('transaction_read_only');"
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select * from test1 order by id; select * from test2 order by id;"
docker exec -e PGPASSWORD=postgres standby psql -U postgres -d appdb -c "select * from test1 order by id; select * from test2 order by id;"
```

Ожидаемо:
- `primary` снова основной узел
- `standby` снова резервный узел
- на `primary` `transaction_read_only = off`
- на `standby` `pg_is_in_recovery = t`
- на `standby` `transaction_read_only = on`
- на обоих узлах есть все строки, включая `after_failover_rw1` и `3030`

#### Шаг 4. Финально показать чтение/запись после восстановления

Откройте 3 терминала.

Терминал 1, клиент записи на восстановленном `primary`:

```bash
docker exec -e PGAPPNAME=client_rw_restored -e PGPASSWORD=postgres -it primary psql -U postgres -d appdb
```

Терминал 2, клиент чтения на восстановленном `standby`:

```bash
docker exec -e PGAPPNAME=client_ro_restored -e PGPASSWORD=postgres -it standby psql -U postgres -d appdb
```

Терминал 3, мониторинг:

```bash
docker exec -e PGPASSWORD=postgres primary psql -U postgres -d appdb -c "select application_name, state, backend_type from pg_stat_activity where datname = 'appdb' order by application_name, pid;"
```

В `client_rw_restored`:

```sql
\pset pager off
show transaction_read_only;
begin;
insert into test1(value) values ('restored_primary_check');
insert into test2(amount) values (4040);
commit;
select * from test1 order by id desc limit 3;
select * from test2 order by id desc limit 3;
```

В `client_ro_restored`:

```sql
\pset pager off
show transaction_read_only;
select * from test1 order by id desc limit 3;
select * from test2 order by id desc limit 3;
```

Ожидаемо:
- на восстановленном `primary` `transaction_read_only = off`
- на восстановленном `standby` `transaction_read_only = on`
- строки `restored_primary_check` и `4040` сразу видны на резервном узле

## Короткая версия для защиты

Можно говорить так:

1. Поднимаю два узла PostgreSQL: основной и резервный.
2. На основном сервере показываю чтение/запись, на резервном показываю `read only`.
3. Создаю несколько клиентских подключений и записываю новые строки на `primary`.
4. Показываю, что эти строки уже синхронизировались на `standby`.
5. Имитирую внезапное отключение основного узла через `SIGKILL`.
6. В логах показываю потерю WAL stream и ожидание WAL на резерве.
7. Выполняю `pg_promote()` и перевожу резервный узел в новый основной.
8. После failover снова открываю клиентские подключения и показываю чтение/запись уже на бывшем `standby`.
9. Затем переснимаю старый `primary` с нового основного узла, возвращаю его в строй и снова делаю основным.
10. Пересобираю `standby` от восстановленного `primary` и показываю, что исходная схема и репликация снова работают.

## Повторный запуск после демонстрации

Если нужно быстро начать заново, выполните блок из раздела `Чистый старт перед защитой`.

Если нужно именно показать возврат в исходную конфигурацию после failover, выполните раздел `2.4 Возврат к исходной конфигурации`.
