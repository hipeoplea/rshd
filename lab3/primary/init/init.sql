CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';

CREATE TABLE IF NOT EXISTS test1 (
    id serial PRIMARY KEY,
    value text NOT NULL
);

CREATE TABLE IF NOT EXISTS test2 (
    id serial PRIMARY KEY,
    amount integer NOT NULL
);

INSERT INTO test1(value) VALUES ('row1'), ('row2');
INSERT INTO test2(amount) VALUES (10), (20);