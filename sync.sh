#!/bin/bash
# v4 resync: copy missing/updated rows source->target by PK. Never writes to source. Usage env: SYNC_STEP, SYNC_SINCE, SEQ_MARGIN
M(){ echo "MARKER $(date -u +%H:%M:%S) $*"; }
export PGCONNECT_TIMEOUT=20 LC_ALL=C
S(){ psql "$SRC_URL" -X "$@"; }; D(){ psql "$DST_URL" -X "$@"; }
D -q -c "create schema if not exists _migrate; create table if not exists _migrate.state(step text primary key, at timestamptz default now());" || { M DST_UNREACHABLE; exit 1; }
if [ -n "$(D -At -c "select 1 from _migrate.state where step='$SYNC_STEP'")" ]; then M ALREADY_DONE $SYNC_STEP; exit 0; fi
M START $SYNC_STEP since=$SYNC_SINCE margin=$SEQ_MARGIN
S -At -c "select count(*) from public.cardar_import_jobs where status in ('pending','processing')" | sed 's/^/MARKER SRC_ACTIVE_JOBS /'
TABLES=$(S -At -c "select tablename from pg_tables where schemaname='public' order by 1")
fails=""
sync_table(){ local T="$1" P C UPD MC MX
  P=$(S -At -c "select string_agg(quote_ident(a.attname),',' order by array_position(i.indkey,a.attnum)) from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=any(i.indkey) where i.indrelid=format('public.%I','$T')::regclass and i.indisprimary")
  [ -z "$P" ] && { M NOPK "$T"; return 0; }
  C=$(S -At -c "select string_agg(quote_ident(attname),',' order by attnum) from pg_attribute where attrelid=format('public.%I','$T')::regclass and attnum>0 and not attisdropped and attgenerated=''")
  UPD=$(S -At -c "select 1 from information_schema.columns where table_schema='public' and table_name='$T' and column_name='updated_at'")
  S -At -c "copy (select row($P)::text from public.\"$T\") to stdout" | sort > /tmp/s.k || return 1
  D -At -c "copy (select row($P)::text from public.\"$T\") to stdout" | sort > /tmp/d.k || return 1
  comm -23 /tmp/s.k /tmp/d.k > /tmp/f.k; MC=$(wc -l </tmp/f.k); MX=$(comm -13 /tmp/s.k /tmp/d.k | wc -l)
  if [ -n "$UPD" ]; then S -At -c "copy (select row($P)::text from public.\"$T\" where updated_at > '$SYNC_SINCE') to stdout" >> /tmp/f.k; fi
  sort -u -o /tmp/f.k /tmp/f.k; local N=$(wc -l </tmp/f.k)
  [ "$MX" != 0 ] && M EXTRA_ON_TARGET "$T" n=$MX
  [ "$N" = 0 ] && return 0
  S -q <<SQL || return 1
create temp table k(k text); \copy k from '/tmp/f.k'
\copy (select $C from public."$T" t where row($P)::text in (select k from k)) to '/tmp/rows.copy'
SQL
  local SET=$(S -At -c "select string_agg(format('%I=excluded.%I',attname,attname),',' order by attnum) from pg_attribute where attrelid=format('public.%I','$T')::regclass and attnum>0 and not attisdropped and attgenerated='' and attidentity<>'a' and not (attnum = any (coalesce((select indkey::int2[] from pg_index where indrelid=format('public.%I','$T')::regclass and indisprimary), '{}'::int2[])))")
  [ -z "$SET" ] && SET=$(echo "$P" | cut -d, -f1 | sed 's/.*/&=excluded.&/')
  local OV=$(S -At -c "select 'overriding system value' from pg_attribute where attrelid=format('public.%I','$T')::regclass and attidentity='a' limit 1")
  D -q -v ON_ERROR_STOP=1 <<SQL || return 1
begin;
create temp table s as select $C from public."$T" limit 0;
\copy s from '/tmp/rows.copy'
alter table public."$T" disable trigger user;
insert into public."$T"($C) $OV select $C from s on conflict ($P) do update set $SET;
alter table public."$T" enable trigger user;
commit;
SQL
  M SYNCED "$T" missing=$MC upserted=$N
}
pending="$TABLES"
for pass in 1 2 3; do next=""
  for T in $pending; do sync_table "$T" || { next="$next $T"; M SYNC_FAIL pass=$pass "$T"; }; done
  pending="$next"; [ -z "$pending" ] && break; sleep 20; done
[ -n "$pending" ] && M UNSYNCED $pending
# sequences
S -At -c "select format('%s|%s|%s', c.relname, quote_ident(a.attname), pg_get_serial_sequence(format('public.%I',c.relname), a.attname)) from pg_attribute a join pg_class c on c.oid=a.attrelid where c.relnamespace='public'::regnamespace and c.relkind='r' and a.attnum>0 and pg_get_serial_sequence(format('public.%I',c.relname), a.attname) is not null" > /tmp/seqs
while IFS='|' read -r T col seq; do
  v=$(D -At -c "select setval('$seq', greatest(coalesce((select max($col) from public.\"$T\"),0)+$SEQ_MARGIN,1), true)") && M SEQ "$seq" = "$v" || M SEQ_FAIL "$seq"
done < /tmp/seqs
cnt(){ psql "$1" -XAt -c "select format('select %L||''|''||count(*) from public.%I;', tablename, tablename) from pg_tables where schemaname='public' order by 1" | psql "$1" -XAt; }
cnt "$SRC_URL" > /tmp/sc; cnt "$DST_URL" > /tmp/dc
M TABLES src=$(wc -l </tmp/sc) dst=$(wc -l </tmp/dc) rows_src=$(awk -F'|' '{s+=$2}END{print s}' /tmp/sc) rows_dst=$(awk -F'|' '{s+=$2}END{print s}' /tmp/dc)
if diff /tmp/sc /tmp/dc > /tmp/df; then M COUNTS_MATCH yes; else M COUNTS_MATCH no; sed 's/^/MARKER DIFF /' /tmp/df; fi
paste -d'|' /tmp/sc /tmp/dc | awk -F'|' '{printf "%s=%s/%s ", $1,$2,$4} END{print ""}' | fold -w 900 | sed 's/^/MARKER PERTABLE /'
D -At -c "select count(*)||' max_at='||coalesce(max(created_at)::text,'') from public.system_logs" 2>/dev/null | sed 's/^/MARKER DST_SYSLOG /'
S -At -c "select count(*)||' max_at='||coalesce(max(created_at)::text,'') from public.system_logs" 2>/dev/null | sed 's/^/MARKER SRC_SYSLOG /'
[ -z "$pending" ] && D -q -c "insert into _migrate.state(step) values ('$SYNC_STEP')" && M DONE $SYNC_STEP
