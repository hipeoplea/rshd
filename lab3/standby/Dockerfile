FROM postgres:16

COPY postgresql.conf /etc/postgresql/postgresql.conf
COPY pg_hba.conf /etc/postgresql/pg_hba.conf
COPY bootstrap-standby.sh /usr/local/bin/bootstrap-standby.sh

RUN chmod +x /usr/local/bin/bootstrap-standby.sh

CMD ["/usr/local/bin/bootstrap-standby.sh"]