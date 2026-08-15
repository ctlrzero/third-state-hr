# Deploying TS-HR to hr.thirdstate.ae (Vercel)

This app is a static Vite build (React + TypeScript) that talks directly to Supabase from
the browser, so hosting is just "build the static files and serve them" — there's no
server-side component to deploy. `vercel.json` in the project root already contains the
SPA rewrite (`/* -> /index.html`) that `react-router-dom` needs.

I can't do the account-level steps myself (no Vercel login, no access to thirdstate.ae's
DNS), so here's exactly what to do, in order.

## 1. Push the project to a Git repo (recommended) or deploy via CLI

**Git route (recommended — auto-deploys on every push):**
1. Create a repo (GitHub/GitLab/Bitbucket) and push the `ts-hr-frontend` folder to it.
2. In the Vercel dashboard: **Add New → Project → Import** the repo.
3. Vercel auto-detects the Vite framework preset. Confirm:
   - Build command: `npm run build`
   - Output directory: `dist`
   - Install command: `npm install`

**CLI route (no git required):**
```bash
npm i -g vercel
cd ts-hr-frontend
vercel login        # opens a browser to authenticate — do this yourself
vercel               # first deploy, creates the project
vercel --prod        # promote to production
```

## 2. Set environment variables in Vercel

Project → **Settings → Environment Variables**, add for all environments
(Production/Preview/Development):

| Name | Value |
|---|---|
| `VITE_SUPABASE_URL` | `https://yclhzwghzrohusqxfasq.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | `sb_publishable_OJrDvcnHe36xSLLQWBfUew_1ax0GRQQ` |

These are the same values already in `.env.example` in the repo — the anon/publishable
key is meant to be public (it's gated entirely by RLS on the Supabase side), so it's safe
to paste directly into Vercel's env var UI. Redeploy after adding them if you deployed
before setting them.

## 3. Add the custom domain in Vercel

Project → **Settings → Domains** → enter `hr.thirdstate.ae` → **Add**.

Vercel will show you the exact DNS record it wants. For a subdomain (not the apex/root
domain) it's almost always a **CNAME**:

| Type | Name/Host | Value |
|---|---|---|
| CNAME | `hr` | `cname.vercel-dns.com` |

(Use whatever value Vercel displays on that screen — it's occasionally
`cname.vercel-dns-016.com` or similar rotating value, so copy it from the dashboard
rather than assuming it's exactly the above.)

## 4. Add that DNS record at your thirdstate.ae registrar/DNS provider

This has to happen wherever `thirdstate.ae`'s DNS is actually managed (registrar
dashboard, Cloudflare, etc. — I don't know which one you use and have no connector for
it). Steps are the same shape everywhere:

1. Log into the DNS provider for `thirdstate.ae`.
2. Add a **CNAME** record: host `hr`, value = the target Vercel gave you in step 3.
3. Leave TTL at default (or lowest available while testing).
4. Save. DNS propagation is usually minutes, occasionally up to a few hours.

Back in Vercel's Domains screen, it will show "Valid Configuration" once the record
propagates and it can issue the TLS certificate automatically (no action needed from you
there — Vercel handles the certificate).

## 5. Sanity checks after DNS resolves

- Visit `https://hr.thirdstate.ae` — should load the sign-in page.
- Confirm `https://` (not `http://`) works — Vercel auto-provisions and redirects to TLS.
- Try signing in as a real user to confirm the env vars took effect (a blank/broken
  Supabase connection usually means the env vars weren't set before the last deploy —
  redeploy after adding them if so).

## Notes

- No Supabase-side auth redirect URL configuration is needed — this app only uses
  `signInWithPassword` (email/password), not magic links or OAuth, so there's no
  `redirectTo` that needs the new domain whitelisted.
- If you later add password-reset emails, magic links, or OAuth, you'll need to add
  `https://hr.thirdstate.ae` to Supabase → **Authentication → URL Configuration →
  Redirect URLs** at that time.
- The production build was verified clean locally (`tsc -b && vite build`) before writing
  this guide — 88 modules, no type errors.
