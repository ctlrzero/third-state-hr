# Help content

Source for the in-app Help Centre. Readers use `/help`; Owners and Company Admins edit at `/help/admin`.

## Article files

`help-content/articles/<slug>.md`, with front matter, then Markdown:

```
---
title: How to request leave
slug: how-to-request-leave
category: employee            # getting-started | employee | manager | admin
audience: [staff, shift_supervisor]   # staff, shift_supervisor, location_manager, entity_admin, owner
summary: One sentence shown on cards and in search.
related: [other-slug, another-slug]
route: /leave                 # optional: the app screen it documents
last_reviewed: 2026-10-01     # YYYY-MM-DD
status: published
---
Intro paragraph.

## Steps
1. First step.

## What happens next
## Common problems
**Problem.** Solution.
## Related guides
```

Owners and Company Admins can read every published article whatever the audience. Everyone else only sees articles
that list their role. The slug is the permanent web address (`/help/<slug>`), so do not rename it. `admin` is reserved.

Screenshots: `![alt text](shot:<key>)` points to `help-content/screenshots/<key>.png`. `screenshots/manifest.json`
maps each key to `{alt, article, annotations:[{n,label}]}`; the seed adds the numbered labels under the picture.
The quick-start article (`quick-start-for-new-staff`) is pinned at the top of the help home.
Small "Need help?" links on app screens use `<HelpLink slug="..."/>` and show nothing if the slug is unpublished or not for the role.

## Add or change an article

1. Create or edit the `.md` file (and screenshots). Set `last_reviewed` to today.
2. `node scripts/seed-help.mjs` writes `supabase/seed/help_articles_seed.sql`.
3. Run that SQL on the database (Supabase SQL editor or MCP `execute_sql`). It is safe to re-run: articles are matched by
   slug and a new version is created only when the text changed.
4. For new or changed pictures: `SUPABASE_SERVICE_ROLE_KEY=... node scripts/seed-help.mjs --upload`
   (key from the Supabase dashboard; never commit it). Pictures go to the private `help-media` bucket.

Note: seeding overwrites the live text with the file. If an admin edited an article in the app, copy those edits back into
the `.md` file first (or skip re-seeding that article).

## Editing in the app

Owner and Company Admin: **Help & Guides, then Manage articles** (`/help/admin`). Edit title, summary, who can read it,
related guides and the text; upload screenshots and insert them; **Save draft**; **Preview** (same view readers get);
**Publish** (asks for a short change note, creates a new version and sets Last reviewed); **Version history** (view or
restore an older version as a draft); **Mark as reviewed**. Articles not reviewed for 180 days show **Review due**.

## Screenshots

Captured from the running app with demo data, at a fixed viewport, then annotated with numbered markers. Keep the
numbers in `manifest.json` in step with the picture. Retake whenever the screen changes.
