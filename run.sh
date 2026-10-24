#!/bin/bash
SYNC_STEP=sync5 SYNC_SINCE="2026-10-24 10:00:00+00" SEQ_MARGIN=1000 FULL_UPSERT_MAX=50000 MIRROR_DELETE=ALL exec bash /sync.sh
# v3 low-memory, resumable, run-once. secret-free; SRC_URL/DST_URL come from env
M(){ echo "MARKER $(date -u +%H:%M:%S) $*"; }
export PGCONNECT_TIMEOUT=20
D(){ psql "$DST_URL" -X "$@"; }
LOWMEM="-c maintenance_work_mem=16MB -c max_parallel_maintenance_workers=0 -c work_mem=4MB -c statement_timeout=0"
# --- run-once guard (meta lives outside public so the wipe never removes it)
D -q -c "create schema if not exists _migrate; create table if not exists _migrate.state(step text primary key, at timestamptz default now()); create table if not exists _migrate.lock(id int primary key, hb timestamptz);" >/dev/null 2>&1 || { M DST_UNREACHABLE; exit 1; }
st(){ D -At -c "select 1 from _migrate.state where step='$1'" 2>/dev/null | grep -q 1; }
mark(){ D -q -c "insert into _migrate.state(step) values (\$q\$$1\$q\$) on conflict do nothing"; }
if st done; then M ALREADY_DONE; exit 0; fi
if st halt; then M HALTED_PREVIOUSLY see _migrate.state; exit 0; fi
if [ "$(D -At -c "select count(*) from _migrate.lock where hb > now()-interval '40 min'")" != "0" ]; then M LOCKED_OTHER_RUN; exit 0; fi
hb(){ D -q -c "insert into _migrate.lock values(1,now()) on conflict(id) do update set hb=now()" >/dev/null 2>&1; }
hb; T0=$(date +%s); M START v3
halt(){ M HALT "$*"; mark halt; D -q -c "delete from _migrate.lock"; exit 1; }
# try: run command up to 3 times (1 try + 2 retries), waiting for DB recovery
try(){ local n; for n in 1 2 3; do "$@" && return 0; M RETRY $n "$STEP"; sleep 90; hb; done; return 1; }
# --- wipe once
if ! st wiped; then
  D -q -c "drop schema if exists public cascade; create schema public;" || halt wipe
  D -q -v ON_ERROR_STOP=1 -c "create schema if not exists extensions; create extension if not exists pg_trgm schema extensions; create extension if not exists pgcrypto schema extensions; alter database cardar_db set search_path = \"\$user\", public, extensions;" || halt ext
  mark wiped; M WIPED
fi
# --- dump (container is ephemeral, always re-dump)
pg_dump "$SRC_URL" -Fc --no-owner --no-privileges -n public -f /tmp/c.dump || halt dump
M DUMP_OK size=$(du -m /tmp/c.dump|cut -f1)MB
pg_restore -l /tmp/c.dump > /tmp/toc
key(){ sed -E 's/^[0-9]+; [0-9]+ [0-9]+ //' <<<"$1"; }
one(){ printf '%s\n' "$1" > /tmp/one.l; }
# --- pre-data (skip SCHEMA public, its COMMENT, policies; those go/skip later)
if ! st predata; then
  pg_restore -l --section=pre-data /tmp/c.dump | grep -E '^[0-9]+;' | grep -vE ' SCHEMA (- )?public | POLICY ' > /tmp/pre.l
  pg_restore -d "$DST_URL" --no-owner --no-privileges -L /tmp/pre.l /tmp/c.dump 2>/tmp/pre.err
  grep -i error /tmp/pre.err | cut -c1-200 | sort | uniq -c | head -20 | sed 's/^/MARKER PRE_ERR /'
  [ "$(D -At -c "select count(*) from pg_tables where schemaname='public'")" -ge 51 ] || halt "predata tables<51"
  mark predata; M PREDATA_OK n=$(wc -l </tmp/pre.l)
fi
# --- data, table by table, chunked COPY of 50k rows, each chunk its own commit + progress row
grep -E '^[0-9]+; [0-9]+ [0-9]+ TABLE DATA ' /tmp/toc > /tmp/data.l
while IFS= read -r L; do
  K=$(key "$L"); st "D:$K" && continue
  one "$L"; pg_restore -f /tmp/t.sql -L /tmp/one.l /tmp/c.dump || halt "extract $K"
  CP=$(grep -m1 -E '^COPY .* FROM stdin;$' /tmp/t.sql); [ -z "$CP" ] && { mark "D:$K"; continue; }
  awk 'f&&/^\\\.$/{exit} f{print} /^COPY .* FROM stdin;$/{f=1}' /tmp/t.sql > /tmp/rows; rm -f /tmp/t.sql
  rm -f /tmp/ch_*; split -l 50000 -d -a 4 /tmp/rows /tmp/ch_; rm -f /tmp/rows
  for c in /tmp/ch_*; do
    [ -e "$c" ] || continue; ck="C:$K:${c##*_}"; st "$ck" && { rm -f "$c"; continue; }
    { echo "SET search_path='';"; echo "$CP"; cat "$c"; echo '\.'; echo "insert into _migrate.state(step) values (\$q\$$ck\$q\$);"; } > /tmp/cur.sql
    STEP="$ck"; try D -q -1 -v ON_ERROR_STOP=1 -f /tmp/cur.sql >/dev/null || halt "copy $ck"
    rm -f "$c"; sleep 1
  done
  mark "D:$K"; hb; M LOADED "$K"; sleep 3
done < /tmp/data.l
M DATA_DONE secs=$(( $(date +%s)-T0 ))
# sequences
grep -E ' SEQUENCE SET ' /tmp/toc > /tmp/seq.l
if ! st seqs; then [ -s /tmp/seq.l ] && { STEP=seqs; try pg_restore -d "$DST_URL" -L /tmp/seq.l /tmp/c.dump || halt seqs; }; mark seqs; M SEQ_OK; fi
postrun(){ env PGOPTIONS="$LOWMEM" psql "$DST_URL" -Xq -v ON_ERROR_STOP=1 -f /tmp/o.sql >/dev/null 2>/tmp/o.err && return 0
  grep -q 'already exists' /tmp/o.err && return 0; cut -c1-200 /tmp/o.err | sed 's/^/MARKER POST_ERR /'; return 1; }
# --- post-data one object at a time, low memory; order: constraints, indexes, fk, triggers, rls, policies; trigram last
pg_restore -l --section=post-data /tmp/c.dump | grep -E '^[0-9]+;' > /tmp/post.all
{ grep -E ' CONSTRAINT ' /tmp/post.all | grep -v 'FK CONSTRAINT'
  grep -E ' INDEX ' /tmp/post.all | grep -v trgm
  grep -E ' INDEX ' /tmp/post.all | grep trgm | grep -v master_checklist_search_trgm_idx
  grep -E ' FK CONSTRAINT ' /tmp/post.all
  grep -E ' TRIGGER ' /tmp/post.all
  grep -vE ' (CONSTRAINT|INDEX|FK CONSTRAINT|TRIGGER|POLICY) ' /tmp/post.all
  grep -E ' POLICY ' /tmp/post.all
  grep master_checklist_search_trgm_idx /tmp/post.all; } | awk '!s[$0]++' > /tmp/post.l
while IFS= read -r L; do
  K=$(key "$L"); st "P:$K" && continue
  one "$L"; pg_restore -f /tmp/o.sql -L /tmp/one.l /tmp/c.dump
  if grep -qiE 'REFERENCES auth\.|TO authenticated|auth\.(uid|jwt|role)\(' /tmp/o.sql; then mark "P:$K"; M SKIP_SUPABASE "$K"; continue; fi
  STEP="P:$K"; t=$(date +%s)
  try postrun || halt "post $K"
  mark "P:$K"; hb; M POST_OK "$K" secs=$(( $(date +%s)-t )); sleep 2
done < /tmp/post.l
M POST_DONE secs=$(( $(date +%s)-T0 ))
# --- verify
cnt(){ psql "$1" -XAt -c "select format('select %L||''|''||count(*) from public.%I;', tablename, tablename) from pg_tables where schemaname='public' order by 1" | psql "$1" -XAt; }
cnt "$SRC_URL" > /tmp/s.txt; cnt "$DST_URL" > /tmp/d.txt
M TABLES src=$(wc -l </tmp/s.txt) dst=$(wc -l </tmp/d.txt) rows_src=$(awk -F'|' '{s+=$2}END{print s}' /tmp/s.txt) rows_dst=$(awk -F'|' '{s+=$2}END{print s}' /tmp/d.txt)
grep -E '^(Master_Checklist|cardar_import_cards)\|' /tmp/d.txt | sed 's/^/MARKER DSTCOUNT /'
if diff /tmp/s.txt /tmp/d.txt >/tmp/diff.txt; then M COUNTS_MATCH yes; else M COUNTS_MATCH no; sed 's/^/MARKER DIFF /' /tmp/diff.txt | head -40; fi
for u in SRC_URL DST_URL; do M OBJ $u idx=$(psql "${!u}" -XAtc "select count(*) from pg_indexes where schemaname='public'") trg=$(psql "${!u}" -XAtc "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal") fn=$(psql "${!u}" -XAtc "select count(*) from pg_proc where pronamespace='public'::regnamespace") trgm_idx=$(psql "${!u}" -XAtc "select count(*) from pg_indexes where indexname='master_checklist_search_trgm_idx'") pol=$(psql "${!u}" -XAtc "select count(*) from pg_policies where schemaname='public'"); done
psql "$SRC_URL" -XAtc "select indexname from pg_indexes where schemaname='public' order by 1" >/tmp/si; psql "$DST_URL" -XAtc "select indexname from pg_indexes where schemaname='public' order by 1" >/tmp/di
comm -23 /tmp/si /tmp/di | sed 's/^/MARKER MISSING_IDX /'
D -q -c "analyze;" && M ANALYZED
cat > /tmp/q.sql <<'SQL'
\timing on
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%ohtani%' limit 50) x;
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%2024%' and "Search_Text" ilike '%topps%' and "Search_Text" ilike '%chrome%' limit 50) x;
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%wembanyama%prizm%' limit 50) x;
select count(*) from public."Master_Checklist" where "Search_Text" ilike '%judge%';
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%ohtani%' or extensions.similarity("Search_Text",'ohtani')>=0.18 limit 50) x;
SQL
for u in SRC_URL DST_URL; do psql "${!u}" -Xq -c "select 1" >/dev/null
 for i in 1 2 3 4 5; do psql "${!u}" -Xq -f /tmp/q.sql 2>&1 | awk '/^Time:/{print $2} /ERROR/{print "ERR"}' | paste -sd' '; done > /tmp/t_$u
 for q in 1 2 3 4 5; do M SPEED $u q$q median_ms=$(awk -v q=$q '{print $q}' /tmp/t_$u | sort -n | sed -n 3p) all=$(awk -v q=$q '{printf "%s,",$q}' /tmp/t_$u); done
done
D -XAtc "explain select \"Card_ID\" from public.\"Master_Checklist\" where \"Search_Text\" ilike '%ohtani%' limit 50" | sed 's/^/MARKER PLAN_DST /'
mark done; D -q -c "delete from _migrate.lock"
M DB_SIZE src=$(psql "$SRC_URL" -XAtc "select pg_size_pretty(pg_database_size(current_database()))") dst=$(psql "$DST_URL" -XAtc "select pg_size_pretty(pg_database_size(current_database()))")
M DONE total_secs=$(( $(date +%s)-T0 ))
