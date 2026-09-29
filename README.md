# fleet-workflows

Reusable GitHub Actions workflows for the Suraj fleet. Public so private
app repos can call them. Currently: `db-backup-reusable.yml` — guarded
nightly pg_dump (version-matched client, compressed custom format, content
guard, integrity check, retention input, opt-in restore drill). No secrets
or code live here.

## db-backup-reusable.yml

```yaml
jobs:
  backup:
    uses: ykhemani3/fleet-workflows/.github/workflows/db-backup-reusable.yml@main
    with:
      app_id: myapp
      retention_days: 7
    secrets:
      DATABASE_URL_DIRECT: ${{ secrets.DATABASE_URL_DIRECT }}
```

| Input | Default | What it does |
|---|---|---|
| `app_id` | required | Artifact name: `<app_id>-db-<run_id>`, holding `dump.dump` |
| `retention_days` | `7` | How long GitHub keeps the artifact — see the storage arithmetic below |
| `compression` | `zstd:level=9,long` | `pg_dump --compress` spec |
| `min_tables` | `1` | Fail when the dump holds fewer tables |
| `min_rows` | `1` | Fail when the dump holds fewer rows, not counting `_prisma_migrations`, `schema_migrations` or `migrations` tables |
| `restore_drill` | `false` | Also restore the dump into a scratch postgres and check it |
| `restore_schema` | `''` | Restore drill only: restore and check just this schema |

**Content guard.** A wiped database still dumps to tens or hundreds of KB,
because its schema is all still there, so the size of a dump proves nothing.
The guard counts the tables in the dump's table of contents and the rows in
its COPY blocks, and refuses to upload a dump below `min_tables` or
`min_rows`. The migration-bookkeeping tables are left out of the row count
because a reset refills them. The defaults only catch a database with no
tables or no rows; set floors near your real counts (the run log lists the
rows per table) to catch a partial loss. Reading the COPY blocks also
decompresses every data block, so a corrupt dump fails here too.

**Restore drill.** With `restore_drill: true`, after the upload the job
starts `postgres:<major>` (the major version the dump came from), restores
the dump with `pg_restore --no-owner --no-privileges`, and fails unless every
table and row of the dump came back. Restore errors on objects a vanilla
postgres cannot create (a platform extension, a role named in a policy) are
reported as warnings; the table and row checks decide. For a Supabase
database, set `restore_schema: public`. The drill runs after the upload, so
a failed drill never costs the night's backup. Run it weekly from a separate
workflow in the caller repo, keeping its artifact for one day only:

```yaml
name: DB Restore Drill
on:
  schedule:
    - cron: '30 22 * * 6'   # weekly, Saturday 22:30 UTC
  workflow_dispatch: {}
jobs:
  drill:
    uses: ykhemani3/fleet-workflows/.github/workflows/db-backup-reusable.yml@main
    with:
      app_id: myapp-drill
      retention_days: 1
      restore_drill: true
    secrets:
      DATABASE_URL_DIRECT: ${{ secrets.DATABASE_URL_DIRECT }}
```

**Storage arithmetic.** Artifacts of private repos count against one
account-wide Actions storage allowance (the Free plan includes 500 MB). When
it runs out and no spending budget covers the overage, every upload fails
with "Artifact storage quota has been hit", and all callers lose their backup
the same night. The steady state is:

    storage ≈ Σ over callers (dump size × retention_days × runs per day)
              + each weekly drill's dump × 1 day

A 90 MB dump kept 7 days holds 630 MB — over the Free allowance on its own.
Kept 30 days, even a 5 MB dump holds 150 MB. Two levers: `retention_days`
(the default is 7) and `compression`. Measured on two synthetic databases
(one text-heavy, one full of UUIDs), against pg_dump's default gzip:

| `compression` | Size | Time |
|---|---|---|
| `gzip` (pg_dump's default) | 100% | 1× |
| `zstd:level=9,long` (this workflow's default) | 68–87% | 1.6–2.3× |
| `zstd:level=19,long` | 35–64% | 37–42× |

Level 19 is worth its CPU time only for the largest dump. Keep more history
somewhere other than Actions storage, not by raising `retention_days`
across the board.

**Restoring a dump.** It needs pg_restore 17 built with zstd (Homebrew
`postgresql@17` and the apt.postgresql.org packages are).

    gh run download <run-id> -R <owner>/<repo>    # a folder holding dump.dump
    createdb scratch
    pg_restore --no-owner --no-privileges -d scratch <app_id>-db-<run-id>/dump.dump

## Tests

`tests/db-backup.test.sh` runs the workflow's own step scripts, extracted
from the YAML, against throwaway databases: the input contract, the content
guard, and the restore drill. It needs a v17 client on `PATH`, ruby, and a
postgres whose role may create databases. `test.yml` runs it on every push.
