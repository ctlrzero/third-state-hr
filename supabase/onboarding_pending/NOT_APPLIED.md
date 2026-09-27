# Onboarding backend — not applied

These migrations are kept outside `supabase/migrations/` on purpose so no
tooling applies them automatically. Deploy them by hand following `DEPLOY.md` (001–009, 011–013, then 010 with the UI)
(validate with `tests/validate_all_rolled_back.sql` first). Deploy
`010_activation_guard.sql` in the same release as the onboarding UI on this branch.
