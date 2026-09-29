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
  for db in full reset half notables trap drill; do dropdb --if-exists "${PREFIX}_$db" >/dev/null 2>&1; done
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
ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["jobs"]["dump"]["steps"]
  at = ->(n) { steps.index { |s| s["name"] == n } or abort("no step named #{n}") }
  r, g, s, u = ["Restore the last good row count", "Content guard + integrity check",
                "Save this row count as the last good one", "Upload dump as artifact"].map(&at)
  abort("order: restore, guard, save, upload") unless r < g && g < s && s < u
  rw, sw = steps[r]["with"], steps[s]["with"]
  abort("restore and save must use one file and one key") unless rw["path"] == "rows-last-good.txt" && sw["path"] == rw["path"] && sw["key"] == rw["key"]
  abort("restore-keys must be the key up to the run id") unless rw["key"].start_with?(rw["restore-keys"]) && rw["restore-keys"].end_with?(":")
' "$WF" && ok "the baseline is restored before the guard and saved only after it passes" || bad "baseline cache steps"

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
create table "Odd Name" (id int);
insert into "Odd Name" values (1), (2);
insert into app.item values (1, E'two\nlines'), (2, E'back\\\\slash'), (3, E'tab\there'), (4, '\.');
SQL
# What a migrate reset leaves: every table, the migrations rows, and the row a
# migration or seed script puts back (as in dispatch-planner, gatepass,
# slpl-production, attendance and nail-loft-inventory).
make_db reset <<SQL || exit 1
$SCHEMA_SQL
insert into "User" (name) values ('seeded admin');
SQL
# public wiped, another schema untouched: Supabase after a reset of public.
make_db half <<SQL || exit 1
$SCHEMA_SQL
insert into app.item values (1, 'kept');
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
ok "5 databases created"

COMPRESSION=$(input_default compression)
dumped=0
for db in full reset half notables trap; do
  mkdir -p "$WORK/$db"
  run_step "$WORK/$db" dump COMPRESSION="$COMPRESSION" DATABASE_URL_DIRECT="${PREFIX}_$db" \
    && dumped=$((dumped + 1)) || bad "pg_dump --compress=$COMPRESSION of $db"
done
[ "$dumped" -eq 5 ] && ok "dumped with the default compression ($COMPRESSION)" || { echo "cannot test without dumps"; exit 1; }

echo "== content guard"
MAX_DROP=$(input_default max_row_drop_pct)
# No last good backup unless LAST_GOOD holds one ("<rows>TAB<check_schema>").
guard() { # dir min_tables min_rows [check_schema [max_row_drop_pct]]
  rm -f "$WORK/$1/rows-last-good.txt"
  [ -z "${LAST_GOOD:-}" ] || printf '%s\n' "$LAST_GOOD" > "$WORK/$1/rows-last-good.txt"
  run_step "$WORK/$1" guard MIN_TABLES="$2" MIN_ROWS="$3" CHECK_SCHEMA="${4:-}" MAX_ROW_DROP_PCT="${5:-$MAX_DROP}" \
    > "$WORK/$1/guard.out" 2>&1
}
baseline() { cat "$WORK/$1/rows-last-good.txt" 2>/dev/null; }
TAB=$(printf '\t')
if guard full 1 1; then
  grep -q '7 tables, 16 rows (13 outside migration bookkeeping)' "$WORK/full/guard.out" \
    && ok "healthy dump passes and is counted exactly (partitions, escapes, a lone \\., a quoted name)" \
    || { bad "healthy dump counts"; cat "$WORK/full/guard.out"; }
else bad "healthy dump refused"; cat "$WORK/full/guard.out"; fi
[ "$(baseline full)" = "13$TAB" ] && ok "a passing guard records its count as the last good one" || bad "baseline written: '$(baseline full)'"
guard full 7 13 && ok "passes at exactly min_tables=7, min_rows=13" || bad "boundary refused"
guard full 8 1 && bad "min_tables=8 let a 7-table dump through" \
  || { grep -q '7 tables, fewer than min_tables=8' "$WORK/full/guard.out" && ok "min_tables above the dump fails" || bad "min_tables: wrong reason"; }
guard full 1 14 && bad "min_rows=14 let a 13-row dump through" \
  || { grep -q '13 rows outside migration bookkeeping, fewer than min_rows=14' "$WORK/full/guard.out" && ok "min_rows above the dump fails" || bad "min_rows: wrong reason"; }
guard reset 1 1 && ok "limit: with no last good backup, a seeded reset clears min_rows=1" \
  || { bad "seeded reset: expected to pass min_rows=1"; cat "$WORK/reset/guard.out"; }
guard reset 1 2 && bad "min_rows=2 let a seeded reset through" \
  || { grep -q '1 rows outside migration bookkeeping, fewer than min_rows=2' "$WORK/reset/guard.out" \
       && ok "a floor above the seed rows catches a seeded reset" || bad "seeded reset: wrong reason"; }
LAST_GOOD="13$TAB" guard reset 1 1 && bad "a seeded reset passed against yesterday's 13 rows" \
  || { grep -q '1 rows outside migration bookkeeping, down more than max_row_drop_pct=50% from 13' "$WORK/reset/guard.out" \
       && ok "a seeded reset fails at the defaults against the last good backup" || { bad "drop: wrong reason"; cat "$WORK/reset/guard.out"; }; }
[ "$(baseline reset)" = "13$TAB" ] && ok "a failed guard leaves the last good count where it was" || bad "baseline moved on failure: '$(baseline reset)'"
LAST_GOOD="26$TAB" guard full 1 1 && ok "passes at exactly a 50% drop" || bad "50% drop refused"
LAST_GOOD="27$TAB" guard full 1 1 && bad "a drop past 50% passed" \
  || { grep -q 'from 27 at the last good backup' "$WORK/full/guard.out" && ok "a drop past 50% fails" || bad "27: wrong reason"; }
LAST_GOOD="1000$TAB" guard full 1 1 "" 100 && ok "max_row_drop_pct=100 turns the drop check off" || bad "pct=100 still refused"
LAST_GOOD="1000${TAB}public" guard full 1 1 && [ "$(baseline full)" = "13$TAB" ] \
  && ok "a baseline from another check_schema is ignored and replaced" || bad "scope mismatch: '$(baseline full)'"
guard half 1 1 && ok "public wiped, app intact: passes when every schema counts" || bad "half: refused unscoped"
guard half 1 1 public && bad "check_schema=public let a wiped public through" \
  || { grep -q '0 rows outside migration bookkeeping, fewer than min_rows=1' "$WORK/half/guard.out" \
       && ok "check_schema=public catches a wiped public beside intact schemas" || bad "half: wrong reason"; }
guard full 1 4 app && grep -q '1 tables, 4 rows (4 outside migration bookkeeping) in schema app' "$WORK/full/guard.out" \
  && ok "check_schema counts just that schema" || { bad "check_schema counts"; cat "$WORK/full/guard.out"; }
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

drill() { # dir [check_schema] — the guard runs first, as in the workflow
  dropdb --if-exists "${PREFIX}_drill" >/dev/null 2>&1
  guard "$1" 0 0 "${2:-}" || { echo "guard failed before the drill" > "$WORK/$1/drill.out"; return 1; }
  run_step "$WORK/$1" drill DRILL_DB="${PREFIX}_drill" CHECK_SCHEMA="${2:-}" > "$WORK/$1/drill.out" 2>&1
}
if drill full; then
  grep -q 'restore drill: 7 of 7 tables, 16 of 16 rows' "$WORK/full/drill.out" \
    && ok "full restore: every table and row back" || { bad "full restore counts"; cat "$WORK/full/drill.out"; }
else bad "full restore drill failed"; cat "$WORK/full/drill.out"; fi
if drill full app; then
  grep -q 'restore drill: 1 of 1 tables, 4 of 4 rows' "$WORK/full/drill.out" \
    && ok "check_schema=app restores and checks just that schema" || { bad "schema drill counts"; cat "$WORK/full/drill.out"; }
else bad "schema restore drill failed"; cat "$WORK/full/drill.out"; fi
drill full nosuch && bad "a schema with no tables passed" || ok "check_schema with no tables fails"
if drill trap; then bad "rows that did not restore went unnoticed"; cat "$WORK/trap/drill.out"
else
  grep -q 'only 3 of the dump.s 7 rows came back' "$WORK/trap/drill.out" && grep -q 'short: public.trap has 0 of 4 rows' "$WORK/trap/drill.out" \
    && grep -q '::warning::pg_restore reported' "$WORK/trap/drill.out" \
    && ok "missing rows fail the drill, naming the table; the restore error is a warning" || { bad "trap: wrong reason"; cat "$WORK/trap/drill.out"; }
  grep -q 'Failing row contains' "$WORK/trap/drill.out" && bad "a failed COPY's row reached the log" || ok "no row data in the log"
fi

echo "== $pass passed, $failed failed"
[ "$failed" -eq 0 ]
