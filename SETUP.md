# Moving Paper Book to Supabase + GitHub Pages

**All steps done Oct 28, 2026.** Site: https://book.reasurf.com/ (was https://rlach77.github.io/paper-book/) · Supabase project `xbnmrdpbvtsvlmxmzfgi`. Kept for reference (e.g. adding a commissioner).

Steps that need your accounts. Do them in order; each one says what to send back to Claude.
Placeholders: `<ref>` is your Supabase project ref (from `https://<ref>.supabase.co`), `<gh-user>` is the GitHub account the site lives on.

## 1. Supabase project
1. Sign in at https://supabase.com → **New project** (Free plan is fine). Pick a region near your friends and save the database password somewhere.
2. When it's ready: **SQL Editor → New query**, paste all of `supabase/schema.sql`, **Run**.
3. ~~Import the old games~~ — skipped (Oct 28): the daily odds pull loads upcoming games instead. `supabase/import-from-artifact.sql` is still there if wanted later.
4. **Project Settings → API** (or **Data API**): copy the **Project URL** and the **anon / publishable** key.

→ Done (Oct 28): `config.js` has the project URL and publishable key.

→ Send Claude the Project URL and that public key. (Both are meant to be public. Never send the `service_role` / secret key.)

## 2. GitHub account and repo
1. In your own terminal, sign in to the other GitHub account (it's added next to RL-VH, which stays):
   ```
   gh auth login
   ```
   Choose GitHub.com → HTTPS → log in with a web browser, using the other account.

→ Tell Claude the username. Claude will switch `gh` to it, create a **public** repo `paper-book`, push, and turn on GitHub Pages.
The site will be `https://<gh-user>.github.io/paper-book/`. (Pages on a free account needs a public repo; nothing secret is in it.)

## 3. Google sign-in
1. https://console.cloud.google.com → create a project (e.g. "Paper Book").
2. **APIs & Services → OAuth consent screen**: External; app name "Paper Book"; your email for support and developer contact; scopes: just the defaults (email, profile, openid). Then **Publish app** (in "Testing" mode only listed test users can sign in; publishing with these basic scopes needs no Google review).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**: type **Web application**.
   - Authorized JavaScript origins: `https://<gh-user>.github.io`
   - Authorized redirect URIs: `https://<ref>.supabase.co/auth/v1/callback`
   Copy the **Client ID** and **Client secret**.
4. Supabase → **Authentication → Sign In / Providers → Google**: enable, paste the client ID and secret, save.
5. Supabase → **Authentication → URL Configuration**:
   - Site URL: `https://<gh-user>.github.io/paper-book/`
   - Redirect URLs: add `https://<gh-user>.github.io/paper-book/**` and `http://localhost:8000/**`

## 4. Make yourself commissioner
Open the site, **Sign in with Google**, join with your handle. Then in the Supabase SQL editor (use the Google email you signed in with):
```sql
insert into public.admins (user_id) select id from auth.users where email = 'you@gmail.com';
```
Reload the site and the **Run the book** tab appears.

## 5. Hourly odds pull (runs on Supabase, Mac can be off)
1. Make a random secret in your terminal and keep it handy: `openssl rand -hex 24`
2. Supabase → **Edge Functions → Secrets**: add
   - `ODDS_API_KEY` = your Odds API key
   - `CRON_SECRET` = the random secret from step 1
3. **Edge Functions → Deploy a new function → Via Editor**: name it `odds-pull`, replace the sample code with all of `supabase/functions/odds-pull/index.ts`, **Deploy**. Then in the function's **Details/Settings**, turn **Verify JWT** (Enforce JWT verification) **off** (the function checks the secret itself).
4. **SQL Editor**: open `supabase/schedule.sql`, replace `YOUR-PROJECT-REF` and `PASTE-CRON-SECRET`, **Run**. Then run the "Run it once right now" lines at the bottom to load today's games and confirm it works (status 200 with a summary).

→ Tell Claude when it's done. Claude then turns off the old claude.ai daily task so the two don't both run.

## Later
- Friends: copy the invite link from **Run the book** and send them that (the book is invite-only). They sign in with Google and pick a handle. Plain link without the invite → they can watch but not join.
- Another commissioner: same `insert into public.admins …` with their email.
- The old claude.ai artifact can be deleted once you're happy with the new site (ask Claude).
