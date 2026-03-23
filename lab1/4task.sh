SELECT t.spcname AS tablespace_name,
       c.relname AS object_name,
       c.relkind AS object_type
FROM pg_class c
JOIN pg_tablespace t ON c.reltablespace = t.oid;

SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       t.spcname AS tablespace_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relkind = 'r'   -- обычные таблицы
ORDER BY t.spcname, n.nspname, c.relname;