#!/bin/sh

export PGDATA=$HOME/ihv13
export PGENCODE=KOI8-R
export PGLOCALE=ru_RU.KOI8-R
export PGUSERNAME=postgres8

initdb -D "$PGDATA" --encoding=$PGENCODE --locale=$PGLOCALE --lc-messages=$PGLOCALE --lc-monetary=$PGLOCALE --lc-numeric=$PGLOCALE --lc-time=$PGLOCALE --username=$PGUSERNAME

pg_ctl -D $PGDATA -l $PGDATA/server.log start