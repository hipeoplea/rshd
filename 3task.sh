mkdir -p /var/db/postgres8/aiz26 /var/db/postgres8/myj76 /var/db/postgres8/zvq81

CREATE TABLESPACE ts_aiz26 LOCATION '/var/db/postgres8/aiz26';
CREATE TABLESPACE ts_myj76 LOCATION '/var/db/postgres8/myj76';
CREATE TABLESPACE ts_zvq81 LOCATION '/var/db/postgres8/zvq81';

CREATE DATABASE easygoldlab TEMPLATE template1;

CREATE ROLE user1
  LOGIN
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
  PASSWORD 'passwd';

GRANT CONNECT ON DATABASE easygoldlab TO user1;

\c easygoldlab
GRANT CREATE ON SCHEMA public TO user1;

GRANT CREATE ON TABLESPACE ts_aiz26 TO user1;
GRANT CREATE ON TABLESPACE ts_myj76 TO user1;
GRANT CREATE ON TABLESPACE ts_zvq81 TO user1;

psql -h localhost -p 9571 -U user1 -d easygoldlab

CREATE TABLE public.orders (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  customer    text NOT NULL,
  amount      numeric(12,2) NOT NULL
) TABLESPACE ts_aiz26;

CREATE TABLE public.customers (
  id         bigserial PRIMARY KEY,
  full_name  text NOT NULL,
  email      text UNIQUE
) TABLESPACE ts_myj76;

CREATE TABLE public.events (
  id         bigserial PRIMARY KEY,
  happened_at timestamptz NOT NULL DEFAULT now(),
  kind       text NOT NULL,
  payload    text
) TABLESPACE ts_zvq81;

INSERT INTO customers (full_name, email)
SELECT
  format('Customer #%s', g),
  format('user%s@example.com', g)
FROM generate_series(1, 1000) AS g;

INSERT INTO orders (customer, amount)
SELECT
  format('Customer #%s', (1 + floor(random() * 1000))::int),
  round((random() * 10000)::numeric, 2)
FROM generate_series(1, 5000);

INSERT INTO events (kind, payload)
SELECT
  (ARRAY['login','purchase','logout','error'])[1 + floor(random() * 4)] AS kind,
  md5(random()::text) AS payload
FROM generate_series(1, 20000);

