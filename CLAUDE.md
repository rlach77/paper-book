# Paper Book

A fake-money sportsbook for a group of friends. Everyone gets 1,000 units **per week** (unbet units don't carry over), makes spread / total / moneyline picks (straight or parlayed) on NFL, NBA and NHL games, and climbs a shared leaderboard ranked by score = total won − total lost across all weeks. No real money anywhere. Ryan is the commissioner.

## Where it lives

- **Site:** https://book.reasurf.com/ (custom domain, CNAME at Namecheap → rlach77.github.io; the old rlach77.github.io/paper-book URL redirects) — GitHub Pages from `main` of the **public** repo `rlach77/paper-book` (personal account, not `RL-VH`; `gh auth switch -u rlach77` before any `gh`/push, and switch back to RL-VH after if needed). Commit/push only when asked.
- **Supabase project:** `xbnmrdpbvtsvlmxmzfgi` (URL + publishable key in `config.js`). Google sign-in, the `odds-pull` Edge Function and its pg_cron schedule are live as of Oct 28, 2026. Ryan's player handle is "Cream AssduelJizzbar".
- **Retired:** the claude.ai artifact https://claude.ai/artifact/3RyqRkx7JViaC3n7C3cKPv and its ArtifactData (delete only if Ryan asks); the claude.ai scheduled task `paper-book-daily-odds` is disabled. `scripts/fetch_odds.py` remains as a manual local pull tool.

## The page

`index.html` is one self-contained file (HTML + CSS + vanilla JS, no build step). It loads supabase-js 2.45.4 from jsdelivr and `config.js` (project URL + public anon/publishable key — safe to commit; access is enforced by RLS). With placeholder config it shows "The book isn't connected".

- Colors are tokens on `:root` with dark-mode overrides under both `@media (prefers-color-scheme: dark) :root:not([data-theme="light"])` and `:root[data-theme="dark"]`. Keep that shape.
- Must work at ~400px width (16px gutter). On ≤520px the odds columns are fixed at 66px so team names get room.
- Branding: the banner and `<title>` read "Todd Albert’s Cuckin’ Sports Book" (Ryan's choice); "Paper Book" is just the project/repo name.
- Display names: players change theirs in My picks (the name pill in the top bar links there). `nameProblem()` enforces 2–20 chars and no case-insensitive duplicates — client-side only.
- Sign-in: `sb.auth.signInWithOAuth({ provider: 'google' })` with the PKCE flow, redirecting back to the same page. Hard-won details (Oct 28): `detectSessionInUrl` is off and `boot()` calls `exchangeCodeForSession(?code)` itself, because in Safari the library's own URL check said "not a PKCE flow" and silently skipped it; the client uses a per-tab `lock` (`tabLock`) instead of `navigator.locks`, because one stuck tab froze every other tab on "Loading…". `boot()` shows "Google sign-in failed: …" (with the auth library's debug log) and, after 10s, "Stuck at …" — keep these until sign-in has been solid for a while. `S.me` = `auth.uid()`; `S.isOwner` = `rpc('is_admin')`. Signed-out visitors can see everything but not pick.
- Data layer (`// ---------- data (Supabase) ----------`): tables are snake_case, the page keeps its old camelCase fields via `GAME_COLS` / `PLAYER_COLS`. `loadAll()` loads all players, games from the last 21 days, plus any older game referenced by a ticket. Realtime `postgres_changes` on `games` and `players` keeps it live; it reloads when the tab becomes visible again. Writes go through `api.*`, which fold the returned row into state.
- Line moves (`// ---------- line moves ----------`): `loadAll()` also loads `line_history` for the loaded games (realtime INSERTs keep it live). Each card shows a small step chart for spread, total and moneyline (home side, or the away side if only that one moved) once that metric has had 2+ distinct values; price-only changes (−110 → −115) aren't charted; spread and moneyline both plot "home more favored" as up (spread negated, moneyline on implied win chance), total higher = up. Native SVG `<title>` per change point is the hover label. History starts when a game is first inserted, so lines before the move to Supabase aren't there.
- Time zones: times show in the viewer's device zone by default, with a zone label ("8:15 PM EST"). The board's "Times in" picker (`TZS`) overrides it per browser (`localStorage` `pb-tz`, so not synced across devices); `fmtKick`, `dayKey` and the line-chart hovers honor it via `tzOpt()`. The Run the book form shows and reads start times in that zone too (`toLocalInput` / `fromLocalInput`). Week numbers stay on UTC (`WEEK1`).
- Team badges: `TEAMS` maps full team name (accents and periods stripped) → `ABBR primary ring` colors; original monogram graphics, not team logos. Add a team there if a new name shows up (fallback is a grey badge).

## Data model (`supabase/schema.sql`)

```
games:   id text pk, league, week int, away, home, starts_at timestamptz,
         away_ml, home_ml, home_spread numeric, spread_odds (home), away_spread_odds (null = same),
         total numeric, total_odds (over), under_odds (null = same), final jsonb {away,home}, locked bool, source, updated_at
players: id uuid pk = auth.users.id, handle (2–20 chars), joined_at, bets jsonb
admins:  user_id uuid pk          -- commissioners; is_admin() checks auth.uid() against it
line_history: id, game_id → games (cascade), at, away_ml, home_ml, home_spread, spread_odds, total, total_odds
         -- written only by trigger record_lines() on games insert and on any change to those columns

bets: [ { id, gameId, market: "ml"|"spread"|"total", side: "home"|"away"|"over"|"under", line, odds, stake, week, placedAt }
      | { id, market: "parlay", legs: [ { gameId, market, side, line, odds } ], odds, stake, week, placedAt } ]
```

RLS: anyone (even signed out) reads games and players; only admins write games; each user inserts/updates only their own player row (admins any). Trigger `check_bets` rejects adding, changing or removing any ticket that touches a game that has started, is final or is locked, and new tickets on unknown games (errors carry hint `game_started` / `game_missing`, mapped in `failMsg`). **Weekly bankroll limits are still only enforced in the page.**

Bets store the line and odds at pick time. Grading and bankrolls are client-side (`grade()`, `outcome()`, `statsFor()`); settling = setting `games.final`. Per week W: left to bet = 1000 + net of settled week-W picks − open week-W stakes. Score = net of all settled picks. Book weeks run Tue→Mon on the NFL calendar (`WEEK1` = Tue Sep 8 2026 12:00Z in `index.html`, the edge function and `scripts/fetch_odds.py`), so NBA/NHL share the NFL week number. `curWeek()` = lowest week with an unsettled game.

Parlays: 2–8 legs, one per market per game (same-game parlays allowed; tapping the other side of a market swaps it), same week. Legs are priced as independent (odds multiplied), so correlated same-game legs pay more than a real book would — fine for fake money. `clash()` blocks the one impossible combo from a parlay (not from singles): a moneyline on one team plus the other team's spread at ≤ 0 (laying points or PK). Client-side only. Any leg lost → lost; pushed legs drop out; legs on deleted games are void. Payout = stake × (product of winning legs' decimal odds − 1). The slip can also place the legs as equal-stake singles; on phones it collapses to a bar.

## Hourly odds and scores (`supabase/functions/odds-pull/index.ts`)

Deno Edge Function, called every hour on the hour by pg_cron (`supabase/schedule.sql`; switched from daily on Oct 28 after Ryan moved to the Odds API 20K-credit/month plan) with an `x-cron-secret` header (deployed with JWT verification off). Secrets: `ODDS_API_KEY`, `CRON_SECRET`, optional `ODDS_BOOK` (default draftkings). Pulls every listed upcoming NFL/NBA/NHL game (no time cap — Ryan wants far-off listed games like NBA Christmas kept), then: new id `<league>-<event id>` → insert, unless a game already on the board has the same home + away within 36h (hand-entered `w9-…` games), which is updated in place; open games → update only changed line columns, re-checking final/locked/started in the update; started/final/locked or starting within 15 min → skipped. Before the lines it settles finished games: for each league with a started, unsettled game from the last 3 days it calls `/scores?daysFrom=3` (2 credits) and sets `final = {away, home}` on completed games (matched by `<league>-<event id>`, or home + away within 36h for hand-entered games; only while `final` is still null; locked games settle too). Older unsettled games come back in `needsHand`. Credits: 9 a run for lines + up to 6 for scores ≤ 15 a run ≈ 11,000/month hourly, against the 20,000/month plan — every 30 min would exceed it. `lowCredits` flags < 1000. Returns and logs a JSON summary (`settled`, `waitingOnScores`, `needsHand`, `added`, `moved`, …). Books list NFL ~a week out, NBA/NHL ~1–2 days out.

Lines: running in production since Oct 28. Score settling: tested only in a browser harness (TypeScript transpiled, fake Odds API + fake DB; no Deno on the Mac). Deploying a change = paste `index.ts` into the dashboard editor for `odds-pull` and Deploy.

## Local preview

```
python3 scripts/build_preview.py && python3 -m http.server 8000
# you (admin):  http://localhost:8000/dev/preview.html
# a friend:     http://localhost:8000/dev/preview.html?as=u_friend&owner=0   (another tab → live updates)
# signed out:   ?as=none     reseed: &reset=1
```

`dev/mock-supabase.js` stands in for supabase-js with localStorage (no RLS or pick-lock trigger; it does imitate the line_history trigger, and on reset adds made-up earlier lines for the first three seed games so charts show). `dev/preview.html` is generated. No Node on Ryan's Mac; `brew` is available. The Supabase CLI isn't installed — SETUP.md uses the dashboard (`supabase/config.toml` is there if the CLI is added later).

## Ideas not built yet

Server-side weekly bankroll check; push-style reminders before lock.
