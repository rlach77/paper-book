# Paper Book

Pick'em sportsbook for friends — fake money only. NFL, NBA and NHL; 1,000 units a week; straights and parlays.

- `index.html` + `config.js` — the whole app, served as a static site (GitHub Pages); data and Google sign-in via Supabase
- `supabase/schema.sql` — tables, access rules, pick-lock trigger
- `supabase/functions/odds-pull/` — hourly Edge Function that loads games, lines and final scores from The Odds API (`supabase/schedule.sql` schedules it)
- `supabase/import-from-artifact.sql` — one-time import of the games from the old claude.ai version
- `dev/` + `scripts/build_preview.py` — run it locally against a mocked Supabase
- `seed/games.json` — sample NFL Week 9 2026 slate used by the local preview

`SETUP.md` walks through creating the Supabase project, Google sign-in and GitHub Pages. `CLAUDE.md` has the data model and internals.
