// Daily odds pull: every listed upcoming NFL/NBA/NHL game from The Odds API → public.games.
// Called by pg_cron (supabase/schedule.sql) with an x-cron-secret header; deploy with JWT verification OFF.
// Secrets (Dashboard → Edge Functions → Secrets): ODDS_API_KEY, CRON_SECRET; optional ODDS_BOOK (default draftkings).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//
// Same rules as the old scripts/plan_odds_writes.py:
// - new game → insert, unless a game already on the board has the same home + away teams starting within 36h
//   (a hand-entered game), which is then updated in place instead of duplicated
// - open game → update only the line columns that changed
// - started / final / locked games, and anything starting within 15 min, are left alone
// Scores, locks and everyone's tickets are never touched.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SPORTS: Record<string, string> = { nfl: "americanfootball_nfl", nba: "basketball_nba", nhl: "icehockey_nhl" };
// Book weeks run Tue→Mon on the NFL calendar; must match WEEK1 in index.html.
const WEEK1 = Date.parse("2026-09-08T12:00:00Z"), WEEK_MS = 7 * 864e5;
const SOON = 15 * 60e3, SAME_GAME = 36 * 3600e3;
const LINE_COLS = ["starts_at", "week", "away_ml", "home_ml", "home_spread", "spread_odds", "away_spread_odds",
  "total", "total_odds", "under_odds", "source"];

type Row = Record<string, unknown>;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "content-type": "application/json" } });

function pickBook(ev: any, prefer: string) {
  const books = ev.bookmakers || [];
  const full = (b: any) => ["h2h", "spreads", "totals"].every((k) => (b.markets || []).some((m: any) => m.key === k));
  return books.find((b: any) => b.key === prefer && full(b)) || books.find(full) || null;
}

function toGame(ev: any, league: string, prefer: string): Row | null {
  const book = pickBook(ev, prefer);
  if (!book) return null;
  const m: Record<string, any[]> = Object.fromEntries(book.markets.map((x: any) => [x.key, x.outcomes]));
  const { home_team: home, away_team: away } = ev;
  const ml = Object.fromEntries(m.h2h.map((o) => [o.name, o.price]));
  const sp = Object.fromEntries(m.spreads.map((o) => [o.name, o]));
  const over = m.totals.find((o) => o.name === "Over"), under = m.totals.find((o) => o.name === "Under");
  if (ml[home] == null || ml[away] == null || !sp[home] || !over) return null;
  return {
    league: league.toUpperCase(), week: Math.floor((Date.parse(ev.commence_time) - WEEK1) / WEEK_MS) + 1,
    away, home, starts_at: ev.commence_time,
    away_ml: ml[away], home_ml: ml[home],
    home_spread: sp[home].point, spread_odds: sp[home].price, away_spread_odds: sp[away]?.price ?? null,
    total: over.point, total_odds: over.price, under_odds: under?.price ?? null,
    source: `odds-api:${book.key}`,
  };
}

const same = (col: string, a: unknown, b: unknown) =>
  col === "starts_at" ? Date.parse(String(a)) === Date.parse(String(b))
  : a == null || b == null ? a == b
  : typeof a === "number" || typeof b === "number" ? Number(a) === Number(b) : a === b;

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);
  const key = Deno.env.get("ODDS_API_KEY");
  if (!key) return json({ error: "ODDS_API_KEY secret is not set" }, 500);
  const prefer = Deno.env.get("ODDS_BOOK") || "draftkings";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const now = Date.now();
  const from = new Date(now).toISOString().replace(/\.\d+Z$/, "Z");
  const pulled = new Map<string, Row>();
  let credits: string | null = null;
  const noLines: string[] = [];
  for (const [lg, sport] of Object.entries(SPORTS)) {
    const q = new URLSearchParams({ apiKey: key, regions: "us", markets: "h2h,spreads,totals", oddsFormat: "american", dateFormat: "iso", commenceTimeFrom: from });
    const r = await fetch(`https://api.the-odds-api.com/v4/sports/${sport}/odds?${q}`);
    if (!r.ok) return json({ error: `${lg}: HTTP ${r.status} ${(await r.text()).slice(0, 300)}` }, 502);
    credits = r.headers.get("x-requests-remaining");
    for (const ev of await r.json()) {
      const g = toGame(ev, lg, prefer);
      if (g) pulled.set(`${lg}-${ev.id}`, g); else noLines.push(`${lg.toUpperCase()} ${ev.away_team} @ ${ev.home_team}`);
    }
  }

  // everything on the board that the pull could overlap, in every league (hand-entered games included)
  const { data: live, error } = await sb.from("games").select("*").gte("starts_at", new Date(now - 864e5).toISOString()).limit(5000);
  if (error) return json({ error: error.message }, 500);
  const byId = new Map(live.map((g: Row) => [g.id as string, g]));

  const inserts: Row[] = [], updates: { id: string; diff: Row; label: string }[] = [];
  let unchanged = 0, skipped = 0;
  for (const [id, g] of pulled) {
    if (Date.parse(g.starts_at as string) - now < SOON) { skipped++; continue; }
    let cur = byId.get(id), target = id;
    if (!cur) {
      const twin = live.find((l: Row) => !pulled.has(l.id as string) && l.home === g.home && l.away === g.away
        && Math.abs(Date.parse(l.starts_at as string) - Date.parse(g.starts_at as string)) <= SAME_GAME);
      if (twin) { cur = twin; target = twin.id as string; }
    }
    if (!cur) { inserts.push({ id, ...g, final: null, locked: false }); continue; }
    if (cur.final || cur.locked || Date.parse(cur.starts_at as string) <= now) { skipped++; continue; }
    const diff: Row = {};
    for (const c of LINE_COLS) if (!same(c, g[c], cur[c])) diff[c] = g[c];
    const keys = Object.keys(diff).filter((k) => k !== "source");
    if (!keys.length) { unchanged++; continue; }
    updates.push({ id: target, diff, label: `${g.league} ${g.away} @ ${g.home}: ` + keys.map((k) => `${k} ${cur![k]}→${diff[k]}`).join(", ") });
  }

  for (let i = 0; i < inserts.length; i += 500) {
    const { error } = await sb.from("games").upsert(inserts.slice(i, i + 500), { onConflict: "id", ignoreDuplicates: true });
    if (error) return json({ error: `insert: ${error.message}` }, 500);
  }
  const moved: string[] = [];
  for (const u of updates) {
    // re-check "still open" in the update itself, in case the game started or was settled/locked meanwhile
    const { data, error } = await sb.from("games").update(u.diff).eq("id", u.id)
      .is("final", null).eq("locked", false).gt("starts_at", new Date().toISOString()).select("id");
    if (error) return json({ error: `update ${u.id}: ${error.message}` }, 500);
    if (data?.length) moved.push(u.label); else skipped++;
  }

  const added: Record<string, number> = {};
  for (const g of inserts) added[g.league as string] = (added[g.league as string] || 0) + 1;
  const summary = {
    added, lineMoves: moved.length, moved, unchanged, skipped, noLines: noLines.length,
    creditsLeft: credits == null ? null : Number(credits),
    lowCredits: credits != null && Number(credits) < 90,
  };
  console.log(JSON.stringify(summary));
  return json(summary);
});
