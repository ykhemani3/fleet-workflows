#!/usr/bin/env bash
# Runs db-backup-reusable.yml's own step scripts (extracted verbatim from the
# YAML) against throwaway local databases, so the guard and the restore drill
# are tested as shipped. Needs: a reachable postgres whose role may create
# databases (PG* env vars, or the local socket), a v17 client on PATH, ruby.
#
#   PATH=/opt/homebrew/opt/postgresql@17/bin:$PATH tests/db-backup.test.sh
#
# Every database it creates is named test_fleetwf_* and dropped on exit.
#
# SC2015: `check && bad ... || ok ...` is safe here, ok and bad always return 0.
# SC2016: the single-quoted strings are ruby programs, not shell.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/db-backup-reusable.yml"
PREFIX=${DB_PREFIX:-test_fleetwf}
WORK=$(mktemp -d)
pass=0; failed=0

cleanup() {
  for db in full reset notables trap drill; do dropdb --if-exists "${PREFIX}_$db" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL $1"; }

# The `run:` body of a step of the dump job, verbatim.
step() {
  ruby -ryaml -e '
    s = YAML.load_file(ARGV[0])["jobs"]["dump"]["steps"].find { |x| x["name"] == ARGV[1] }
    abort("no step named #{ARGV[1]}") unless s
    print s["run"]' "$WF" "$1"
}
# The workflow_call input default (Psych reads the `on:` key as true).
input_default() {
  ruby -ryaml -e '
    w = YAML.load_file(ARGV[0]); on = w["on"] || w[true]
    print on["workflow_call"]["inputs"][ARGV[1]]["default"]' "$WF" "$1"
}

step "Dump" > "$WORK/dump.sh" || exit 1
step "Content guard + integrity check" > "$WORK/guard.sh" || exit 1
step "Start scratch postgres for the restore drill" > "$WORK/start.sh" || exit 1
step "Restore drill" > "$WORK/drill.sh" || exit 1

# Runs a step script the way GitHub runs `shell: bash`, in its own work dir.
run_step() { # dir script [VAR=value ...]
  local dir=$1 script=$2; shift 2
  (cd "$dir" && env "$@" bash --noprofile --norc -eo pipefail "$WORK/$script.sh")
}

echo "== contract (existing callers pass only app_id and retention_days)"
ruby -ryaml -e '
  w = YAML.load_file(ARGV[0]); on = w["on"] || w[true]; wc = on["workflow_call"]
  bad = wc["inputs"].reject { |k, v| k == "app_id" || v.key?("default") }.keys
  abort("inputs without a default: #{bad.join(", ")}") unless bad.empty?
  abort("app_id must stay required") unless wc["inputs"]["app_id"]["required"]
  abort("retention_days must stay an input") unless wc["inputs"].key?("retention_days")
  abort("DATABASE_URL_DIRECT must stay the only secret") unless wc["secrets"].keys == ["DATABASE_URL_DIRECT"]
  runs = w["jobs"]["dump"]["steps"].map { |s| s["run"].to_s }.join
  abort("a run: script uses a ${{ }} expression; pass it through env:") if runs.include?("${{")
' "$WF" && ok "every new input has a default; no expressions inside run: scripts" || bad "input contract"
[ "$(input_default retention_days)" = "7" ] && ok "retention_days defaults to 7" || bad "retention_days default"
[ "$(input_default restore_drill)" = "false" ] && ok "restore drill is opt-in" || bad "restore_drill default"

echo "== fixtures"
make_db() { createdb "${PREFIX}_$1" && psql -X -q -v ON_ERROR_STOP=1 -d "${PREFIX}_$1"; }
SCHEMA_SQL="
  create table _prisma_migrations (id text primary key);
  insert into _prisma_migrations values ('0001'), ('0002'), ('0003');
  create table \"User\" (id serial primary key, name text);
  create table empty_t (id int);
  create table ev (id int, at date) partition by range (at);
  create table ev_2026 partition of ev for values from ('2026-01-01') to ('2027-01-01');
  create schema app;
  create table app.item (id int, note text);"
make_db full <<SQL || exit 1
$SCHEMA_SQL
insert into "User" (name) select 'user ' || g from generate_series(1, 5) g;
insert into ev values (1, '2026-02-01'), (2, '2026-03-01');
insert into app.item values (1, E'two\nlines'), (2, E'back\\\\slash'), (3, E'tab\there'), (4, '\.');
SQL
# What a migrate reset leaves: every table, only the migrations rows.
make_db reset <<SQL || exit 1
$SCHEMA_SQL
SQL
make_db notables </dev/null || exit 1
# A table whose rows cannot load into any other database: the restore drill
# must notice the rows that did not come back.
make_db trap <<SQL || exit 1
create table kept (id int);
insert into kept select generate_series(1, 3);
create table trap (id int, check (current_database() = '${PREFIX}_trap'));
insert into trap select generate_series(1, 4);
SQL
ok "4 databases created"

COMPRESSION=$(input_default compression)
for db in full reset notables trap; do
  mkdir -p "$WORK/$db"
  run_step "$WORK/$db" dump COMPRESSION="$COMPRESSION" DATABASE_URL_DIRECT="${PREFIX}_$db" \
    || { bad "pg_dump --compress=$COMPRESSION of $db"; continue; }
done
ok "dumped with the default compression ($COMPRESSION)"

echo "== content guard"
guard() { run_step "$WORK/$1" guard MIN_TABLES="$2" MIN_ROWS="$3" > "$WORK/$1/guard.out" 2>&1; }
if guard full 1 1; then
  grep -q '6 tables, 14 rows (11 outside migration bookkeeping)' "$WORK/full/guard.out" \
    && ok "healthy dump passes and is counted exactly (partitions, escapes, a lone \\.)" \
    || { bad "healthy dump counts"; cat "$WORK/full/guard.out"; }
else bad "healthy dump refused"; cat "$WORK/full/guard.out"; fi
guard full 6 11 && ok "passes at exactly min_tables=6, min_rows=11" || bad "boundary refused"
guard full 7 1 && bad "min_tables=7 let a 6-table dump through" \
  || { grep -q '6 tables, fewer than min_tables=7' "$WORK/full/guard.out" && ok "min_tables above the dump fails" || bad "min_tables: wrong reason"; }
guard full 1 12 && bad "min_rows=12 let an 11-row dump through" \
  || { grep -q '11 rows outside migration bookkeeping, fewer than min_rows=12' "$WORK/full/guard.out" && ok "min_rows above the dump fails" || bad "min_rows: wrong reason"; }
guard reset 1 1 && bad "a reset database (schema + migrations only) passed" \
  || { grep -q 'fewer than min_rows=1' "$WORK/reset/guard.out" && ok "a reset database fails at the default thresholds" || bad "reset: wrong reason"; }
guard notables 1 1 && bad "a database with no tables passed" \
  || { grep -q 'fewer than min_tables=1' "$WORK/notables/guard.out" && ok "a database with no tables fails" || bad "notables: wrong reason"; }
mkdir -p "$WORK/cut"
size=$(wc -c < "$WORK/full/dump.dump")
head -c $((size * 3 / 4)) "$WORK/full/dump.dump" > "$WORK/cut/dump.dump"
guard cut 1 1 && bad "a truncated dump passed" || ok "a truncated dump fails"

echo "== restore drill"
# The start step, with docker stubbed: it must ask for the dump's own major.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "$@" > "%s/docker.args"\n' "$WORK" > "$WORK/bin/docker"
chmod +x "$WORK/bin/docker"
major=$(psql -X -At -d "${PREFIX}_full" -c "select current_setting('server_version_num')::int / 10000")
if run_step "$WORK/full" start PATH="$WORK/bin:$PATH" PGPORT="${PGPORT:-5432}" > /dev/null 2>&1 \
   && grep -q "postgres:$major\$" "$WORK/docker.args"; then
  ok "scratch server is postgres:$major, the dump's own major"
else bad "start step (docker args: $(cat "$WORK/docker.args" 2>/dev/null))"; fi

drill() { # dir [RESTORE_SCHEMA]
  dropdb --if-exists "${PREFIX}_drill" >/dev/null 2>&1
  run_step "$WORK/$1" drill DRILL_DB="${PREFIX}_drill" RESTORE_SCHEMA="${2:-}" > "$WORK/$1/drill.out" 2>&1
}
guard trap 1 1 || bad "trap dump refused by the guard"
if drill full; then
  grep -q 'restore drill: 6 of 6 tables, 14 of 14 rows' "$WORK/full/drill.out" \
    && ok "full restore: every table and row back" || { bad "full restore counts"; cat "$WORK/full/drill.out"; }
else bad "full restore drill failed"; cat "$WORK/full/drill.out"; fi
if drill full app; then
  grep -q 'restore drill: 1 of 1 tables, 4 of 4 rows' "$WORK/full/drill.out" \
    && ok "restore_schema=app restores and checks just that schema" || { bad "schema drill counts"; cat "$WORK/full/drill.out"; }
else bad "schema restore drill failed"; cat "$WORK/full/drill.out"; fi
drill full nosuch && bad "a schema with no tables passed" || ok "restore_schema with no tables fails"
if drill trap; then bad "rows that did not restore went unnoticed"; cat "$WORK/trap/drill.out"
else
  grep -q 'only 3 of the dump.s 7 rows came back' "$WORK/trap/drill.out" && grep -q '::warning::pg_restore reported' "$WORK/trap/drill.out" \
    && ok "missing rows fail the drill; the restore error is a warning" || { bad "trap: wrong reason"; cat "$WORK/trap/drill.out"; }
  grep -q 'Failing row contains' "$WORK/trap/drill.out" && bad "a failed COPY's row reached the log" || ok "no row data in the log"
fi

echo "== $pass passed, $failed failed"
[ "$failed" -eq 0 ]
