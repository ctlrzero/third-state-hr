# Supabase schema baseline — recovery notes

## How this baseline was produced

The Supabase CLI's normal "existing project" workflow (`supabase link` + `supabase db pull`)
requires `supabase login` (an interactive OAuth flow or a pasted access token). Neither is
available in this environment, and pasting an access token into chat for me to use isn't
something I'll do — that's a credential, same category as a password. So instead, the full
historical SQL was recovered directly from `supabase_migrations.schema_migrations`, the table
Supabase's own migration tracker uses internally to record exactly what was run. This is a
read-only source, not a reconstruction — the `statements` column holds the literal SQL text
that was executed for each of the 99 tracked migrations.

**Result: 99/99 migrations recovered, zero gaps.** (Earlier in this engagement I estimated
"101 migrations" from eyeballing a long tool response — that was my own miscount. The actual,
verified count, confirmed twice independently, is 99.)

## The dblink incident

`20260814164734_enable_dblink_for_autonomous_audit_logging.sql` installs `dblink`.
`20260814165238_remove_dblink_extension.sql`, applied ~30 minutes later, removes it, with this
comment left in place: *"Per explicit user direction: the dblink/autonomous-transaction approach
to logging blocked payroll writes is permanently abandoned. No audit_logger role, password, or
Vault secret was ever created (that step was blocked before execution)."* I independently
grepped all 99 recovered files for `create role`, `create user`, password literals, and Vault/
pgsodium calls — zero matches anywhere. The standing rule (no dblink, no audit-logging
credential) was tested once, caught, and reverted before any credential was created. Currently
clean; keeping this documented rather than silent.

## Items NOT captured by migration replay (must be configured per-environment, manually)

- **Auth configuration** — Site URL, redirect allow-list, email templates, password policy,
  Leaked Password Protection, session expiry, SMTP, CAPTCHA. None of this lives in Postgres;
  it's Supabase project/GoTrue configuration. Every new environment (UAT rename, new PROD
  project) needs this set by hand in the dashboard.
- **Storage bucket restrictions** — `employee-documents` and `candidate-files` are both
  correctly created as private buckets by migration (captured), but `file_size_limit` and
  `allowed_mime_types` are both NULL in the live project right now — no restriction configured.
  Replay reproduces this faithfully (i.e. it's not a recovery gap), but it's worth tightening
  before production.
- **`leave_types` reference data** — 0 rows exist in the live project, and no migration ever
  inserts any. This isn't a recovery gap either (there's nothing to recover), but every
  environment will need at least one leave type entered manually before leave requests are
  usable.
- Edge Functions: none exist — nothing to reconcile.
- Realtime: no tables are in the `supabase_realtime` publication — nothing to reconcile.
- Cron/scheduled jobs: `pg_cron` isn't installed, no `cron.job` table exists — nothing to
  reconcile (also consistent with the standing "no autonomous jobs" rule).
- `entities`, `locations`, `positions`, `app_settings` seed rows ARE fully captured inside
  `20260730192251_seed_data.sql` and `20260813165511_employee_documents_app_settings.sql` —
  confirmed by direct inspection, not assumed.

## Clean local rebuild attempt

`supabase start` (the real local Supabase stack) requires Docker, which isn't available in
this sandbox (no Docker, no sudo/apt). As a substitute I tried applying all 99 migrations in
order against `@electric-sql/pglite` (an embedded Postgres with no Docker requirement). It
failed immediately on migration 1 with `extension "pgcrypto" is not available` — expected,
because a bare Postgres instance doesn't have Supabase's platform schemas (`auth`, `storage`,
`realtime`) or bundled extensions pre-installed the way the real Supabase Docker image does.

**This means a genuine clean-rebuild test has not actually been performed yet.** It needs to
happen from a machine or session with Docker, via `supabase start` + replaying these 99 files.
I did not fabricate a passing result to work around this — reporting the real limitation
instead, per instruction not to claim success without command evidence.

## Proposed migration-history reconciliation plan

1. Treat these 99 files as the authoritative, reviewed baseline — commit as-is, don't edit
   historical statements.
2. Any pre-launch fixes identified in the earlier security/performance audit (RLS
   `auth.uid()` initplan wrapping, duplicate permissive policy consolidation, missing FK
   indexes, `leave_types` seed row, Storage MIME/size limits) should land as new,
   forward-only migrations with today's-or-later timestamps — never edits to the 99 recovered
   files. None have been authored yet in this pass; say the word and I'll draft them as
   separate reviewable migrations.
3. Before this baseline is ever replayed into a new project (UAT rename is a no-op here since
   it's the *same* project; a real replay only matters for the future `TS-HR-PROD` project),
   run the Docker-based clean rebuild for real and treat any failure there as blocking.
