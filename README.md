# fleet-workflows

Reusable GitHub Actions workflows for the Suraj fleet. Public so private
app repos can call them. Currently: `db-backup-reusable.yml` — guarded
nightly pg_dump (version-matched client, custom format, content
guard, integrity check, retention input). No secrets
or code live here.

## db-backup-reusable.yml

```yaml
jobs:
  backup:
    uses: ykhemani3/fleet-workflows/.github/workflows/db-backup-reusable.yml@main
    with:
      app_id: myapp
      retention_days: 30
    secrets:
      DATABASE_URL_DIRECT: ${{ secrets.DATABASE_URL_DIRECT }}
```

| Input | Default | What it does |
|---|---|---|
| `app_id` | required | Artifact name: `<app_id>-db-<run_id>`, holding `dump.dump` |
| `retention_days` | `30` | How long GitHub keeps the artifact |
| `min_tables` | `1` | Fail when the dump holds fewer tables |
| `min_rows` | `1` | Fail when the dump holds fewer rows, not counting `_prisma_migrations`, `schema_migrations` or `migrations` tables |

**Content guard.** A wiped database still dumps to tens or hundreds of KB,
because its schema is all still there, so the size of a dump proves nothing.
The guard counts the tables in the dump's table of contents and the rows in
its COPY blocks, and refuses to upload a dump below `min_tables` or
`min_rows`. The migration-bookkeeping tables are left out of the row count
because a reset refills them. The defaults only catch a database with no
tables or no rows; set floors near your real counts (the run log lists the
rows per table) to catch a partial loss. Reading the COPY blocks also
decompresses every data block, so a corrupt dump fails here too.

## Tests

`tests/db-backup.test.sh` runs the workflow's own step scripts, extracted
from the YAML, against throwaway databases: the input contract and the
content guard. It needs a v17 client on `PATH`, ruby, and a
postgres whose role may create databases. `test.yml` runs it on every push.
