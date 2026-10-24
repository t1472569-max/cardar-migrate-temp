#!/bin/bash
echo "MARKER DISABLED"; exit 0
# secret-free; SRC_URL/DST_URL come from env
M(){ echo "MARKER $*"; }
export PGCONNECT_TIMEOUT=20
if psql "$DST_URL" -XAtc "select 1 from public._migrate_done where v=2" >/dev/null 2>&1; then M ALREADY_DONE; exit 0; fi
T0=$(date +%s); M START v2
psql "$DST_URL" -Xq -c "drop schema public cascade; create schema public;" && M RESET_OK
psql "$DST_URL" -Xq -v ON_ERROR_STOP=1 -c "create schema if not exists extensions; create extension if not exists pg_trgm schema extensions; create extension if not exists pgcrypto schema extensions;" && M EXT_OK || M EXT_FAIL
pg_dump "$SRC_URL" -Fc --no-owner --no-privileges -n public -f /tmp/c.dump && M DUMP_OK size=$(du -m /tmp/c.dump|cut -f1)MB secs=$(( $(date +%s)-T0 )) || { M DUMP_FAIL; exit 1; }
pg_restore -d "$DST_URL" -j 1 --no-owner --no-privileges /tmp/c.dump 2>/tmp/r.err; M RESTORE_DONE rc=$? errors=$(grep -ci 'error' /tmp/r.err) secs=$(( $(date +%s)-T0 ))
grep -i 'error' /tmp/r.err | cut -c1-200 | sort | uniq -c | head -20 | sed 's/^/MARKER RESTORE_ERR /'
psql "$DST_URL" -Xq <<'SQL'
alter database cardar_db set search_path = "$user", public, extensions;
do $$ declare r record; begin
 for r in select conrelid::regclass t, conname from pg_constraint where contype='f' and confrelid::regclass::text like 'auth.%' loop
  execute format('alter table %s drop constraint %I', r.t, r.conname); raise notice 'dropped fk %', r.conname; end loop;
 for r in select schemaname, tablename, policyname from pg_policies where qual ilike '%auth.%' or with_check ilike '%auth.%' loop
  execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename); raise notice 'dropped policy %', r.policyname; end loop;
end $$;
SQL
M CLEANUP_DONE fk_auth_left=$(psql "$DST_URL" -XAtc "select count(*) from pg_constraint where contype='f' and confrelid::regclass::text like 'auth.%'") pol=$(psql "$DST_URL" -XAtc "select count(*) from pg_policies")
cnt(){ psql "$1" -XAt -c "select format('select %L||''|''||count(*) from public.%I;', tablename, tablename) from pg_tables where schemaname='public' and tablename<>'_migrate_done' order by 1" | psql "$1" -XAt; }
cnt "$SRC_URL" > /tmp/s.txt; cnt "$DST_URL" > /tmp/d.txt
M TABLES src=$(wc -l </tmp/s.txt) dst=$(wc -l </tmp/d.txt) rows_src=$(awk -F'|' '{s+=$2}END{print s}' /tmp/s.txt)
if diff /tmp/s.txt /tmp/d.txt >/tmp/diff.txt; then M COUNTS_MATCH yes; else M COUNTS_MATCH no; sed 's/^/MARKER DIFF /' /tmp/diff.txt | head -40; fi
for u in SRC_URL DST_URL; do M OBJ $u idx=$(psql "${!u}" -XAtc "select count(*) from pg_indexes where schemaname='public'") trg=$(psql "${!u}" -XAtc "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal") fn=$(psql "${!u}" -XAtc "select count(*) from pg_proc where pronamespace='public'::regnamespace") trgm_idx=$(psql "${!u}" -XAtc "select count(*) from pg_indexes where indexname='master_checklist_search_trgm_idx'"); done
psql "$SRC_URL" -XAtc "select indexname from pg_indexes where schemaname='public' order by 1" >/tmp/si; psql "$DST_URL" -XAtc "select indexname from pg_indexes where schemaname='public' order by 1" >/tmp/di
comm -23 /tmp/si /tmp/di | sed 's/^/MARKER MISSING_IDX /'
sleep 20; psql "$DST_URL" -Xqc "analyze;" && M ANALYZED
cat > /tmp/q.sql <<'SQL'
\timing on
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%ohtani%' or extensions.similarity("Search_Text",'ohtani')>=0.18 limit 50) x;
select count(*) from (select "Card_ID" from public."Master_Checklist" where "Search_Text" ilike '%2024%' and "Search_Text" ilike '%topps%' and "Search_Text" ilike '%chrome%' limit 50) x;
select count(*) from (select "Set_Name", count(*) from public."Master_Checklist" group by 1 order by 1) x;
select count(*) from (select distinct "Player_Name", extensions.word_similarity('wembanyama',"Player_Name") sim from public."Master_Checklist" where "Player_Name" is not null and "Player_Name"<>'' order by sim desc limit 30) x;
SQL
for u in SRC_URL DST_URL; do psql "${!u}" -Xq -c "select 1" >/dev/null
 for i in 1 2 3 4 5; do psql "${!u}" -Xq -f /tmp/q.sql 2>&1 | awk '/^Time:/{print $2}' | paste -sd' '; done > /tmp/t_$u
 for q in 1 2 3 4; do M SPEED $u q$q median_ms=$(awk -v q=$q '{print $q}' /tmp/t_$u | sort -n | sed -n 3p) all=$(awk -v q=$q '{printf "%s,",$q}' /tmp/t_$u); done
done
psql "$DST_URL" -Xqc "create table if not exists public._migrate_done(v int, at timestamptz default now()); insert into public._migrate_done(v) values (2);"
M DB_SIZE src=$(psql "$SRC_URL" -XAtc "select pg_size_pretty(pg_database_size(current_database()))") dst=$(psql "$DST_URL" -XAtc "select pg_size_pretty(pg_database_size(current_database()))")
M DONE total_secs=$(( $(date +%s)-T0 ))
