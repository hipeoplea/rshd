echo "listen_addresses = 'localhost'" >> $PGDATA/postgresql.conf
echo "port = 9571" >> $PGDATA/postgresql.conf
echo "password_encryption = 'scram-sha-256'" >> $PGDATA/postgresql.conf

cat > $PGDATA/pg_hba.conf << EOF
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

local   all             all                                     peer

host    all             all             0.0.0.0/0               reject
host    all             all             ::0/0                   reject
EOF


pg_ctl -D $PGDATA restart

psql -h /tmp -p 9571 -d postgres


ALTER SYSTEM SET max_connections = '200';
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET temp_buffers = '16MB';
ALTER SYSTEM SET work_mem = '32MB';
ALTER SYSTEM SET checkpoint_timeout = '5min';
ALTER SYSTEM SET effective_cache_size = '24GB';
ALTER SYSTEM SET fsync = 'on';
ALTER SYSTEM SET commit_delay = '2000';
\q


ALTER SYSTEM SET effective_cache_size = '100MB';
ALTER SYSTEM SET shared_buffers = '40MB';
ALTER SYSTEM SET work_mem = '1MB';
ALTER SYSTEM SET temp_buffers = '4MB';
ALTER SYSTEM SET max_connections = 20;
ALTER SYSTEM SET fsync = on;
ALTER SYSTEM SET checkpoint_timeout = '5min';
\q

pg_ctl -D "$PGDATA" restart

echo "logging_collector = on" >> $PGDATA/postgresql.conf
echo "log_directory = 'log'" >> $PGDATA/postgresql.conf
echo "log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'" >> $PGDATA/postgresql.conf
echo "log_file_mode = 0600" >> $PGDATA/postgresql.conf

echo "log_min_messages = info" >> $PGDATA/postgresql.conf

echo "log_connections = on" >> $PGDATA/postgresql.conf
echo "log_disconnections = on" >> $PGDATA/postgresql.conf

pg_ctl -D $PGDATA restart


