# fleet-workflows

Reusable GitHub Actions workflows for the Suraj fleet. Public so private
app repos can call them. Currently: `db-backup-reusable.yml` — guarded
nightly pg_dump (version-matched client, custom format, empty-dump guard,
integrity check, retention input). No secrets or code live here.
