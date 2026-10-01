# Third State HR

## Help centre

The in-app Help Centre (`/help`, editor at `/help/admin`) is the user manual. Article source lives in
`help-content/articles/*.md`, screenshots in `help-content/screenshots/`, and the live copy in the database
(`help_articles`). See `help-content/README.md` for the file format and commands.

Whenever a user-facing workflow, menu name, button label or status changes, you must:

1. Review and update the matching help article(s) in `help-content/articles`.
2. Retake or update the affected screenshots in `help-content/screenshots` (and `manifest.json`).
3. Re-seed (`node scripts/seed-help.mjs`, apply `supabase/seed/help_articles_seed.sql`, add `--upload` for new images).
4. Bump `last_reviewed` in the article front matter to today.

Use plain-English role names in help text: Company, Company Admin, Branch Manager, Shift Supervisor, Employee.
