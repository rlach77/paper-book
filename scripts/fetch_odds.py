#!/usr/bin/env python3
"""Pull one book week of games + lines from The Odds API and write them as Paper Book `games` docs.

The artifact page can't call outside hosts (and a key in the page would be public), so odds are
pulled here and then written to the artifact's database with the ArtifactData tool (see CLAUDE.md).

    export ODDS_API_KEY=...          # never commit it
    python3 scripts/fetch_odds.py                      # current book week, NFL+NBA+NHL
    python3 scripts/fetch_odds.py --week 10 --leagues nba,nhl --book fanduel
    python3 scripts/fetch_odds.py --days 3 --leagues nba,nhl     # rolling: now -> 3 days out
    python3 scripts/fetch_odds.py --all                          # every listed game from now on (daily job)

Books only list games once lines are posted: NFL about a week ahead, NBA/NHL ~1-2 days ahead (plus a few
marquee games like Christmas), so pulling --all daily picks games up as they appear.

Output: odds/week<N>.json, odds/next<D>d.json or odds/upcoming.json  ->  { "<docId>": { league, week, away, home, startsAt, awayML, homeML,
                                               homeSpread, total, spreadOdds, totalOdds, final, locked } }
Doc ids are "<league>-<odds api event id>", so re-running updates the same docs instead of duplicating.
Each call costs 3 credits per league (h2h + spreads + totals, one region).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

API = "https://api.the-odds-api.com/v4/sports/{sport}/odds"
SPORTS = {"nfl": "americanfootball_nfl", "nba": "basketball_nba", "nhl": "icehockey_nhl"}
# Book weeks run Tue -> Mon on the NFL calendar; must match WEEK1 in index.html.
WEEK1 = datetime(2026, 9, 8, 12, 0, tzinfo=timezone.utc)


def week_window(week):
    start = WEEK1 + timedelta(weeks=week - 1)
    return start, start + timedelta(weeks=1)


def week_of(dt):
    return (dt - WEEK1) // timedelta(weeks=1) + 1


def current_week():
    return week_of(datetime.now(timezone.utc))


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch(sport, key, start, end, region):
    q = urllib.parse.urlencode({
        "apiKey": key, "regions": region, "markets": "h2h,spreads,totals", "oddsFormat": "american",
        "dateFormat": "iso", "commenceTimeFrom": iso(start),
        **({"commenceTimeTo": iso(end)} if end else {}),
    })
    try:
        with urllib.request.urlopen(f"{API.format(sport=sport)}?{q}", timeout=30) as r:
            left = r.headers.get("x-requests-remaining")
            return json.load(r), left
    except urllib.error.HTTPError as e:
        sys.exit(f"{sport}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")


def pick_book(event, prefer):
    books = event.get("bookmakers") or []
    for b in books:
        if b["key"] == prefer:
            return b
    # fall back to the first book that has all three markets
    for b in books:
        if {m["key"] for m in b.get("markets", [])} >= {"h2h", "spreads", "totals"}:
            return b
    return books[0] if books else None


def to_game(event, league, prefer):
    book = pick_book(event, prefer)
    if not book:
        return None, "no bookmakers"
    m = {mk["key"]: mk["outcomes"] for mk in book.get("markets", [])}
    if not {"h2h", "spreads", "totals"} <= m.keys():
        return None, f"{book['key']} missing {sorted({'h2h', 'spreads', 'totals'} - m.keys())}"
    home, away = event["home_team"], event["away_team"]
    ml = {o["name"]: o["price"] for o in m["h2h"]}
    sp = {o["name"]: o for o in m["spreads"]}
    over = next((o for o in m["totals"] if o["name"] == "Over"), None)
    under = next((o for o in m["totals"] if o["name"] == "Under"), None)
    if home not in ml or away not in ml or home not in sp or not over:
        return None, "incomplete outcomes"
    return {
        "league": league.upper(),
        "week": week_of(datetime.fromisoformat(event["commence_time"].replace("Z", "+00:00"))), "away": away, "home": home,
        "startsAt": event["commence_time"],
        "awayML": ml[away], "homeML": ml[home],
        "homeSpread": sp[home]["point"],
        "spreadOdds": sp[home]["price"], "awaySpreadOdds": sp[away]["price"] if away in sp else None,
        "total": over["point"], "totalOdds": over["price"], "underOdds": under["price"] if under else None,
        "final": None, "locked": False,
        "source": f"odds-api:{book['key']}",
    }, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    when = ap.add_mutually_exclusive_group()
    when.add_argument("--week", type=int, help="book week (default: this week)")
    when.add_argument("--days", type=int, help="rolling window: games starting from now to N days out")
    when.add_argument("--all", action="store_true", help="every listed game starting from now")
    ap.add_argument("--leagues", default="nfl,nba,nhl")
    ap.add_argument("--book", default="draftkings", help="preferred bookmaker key")
    ap.add_argument("--region", default="us")
    ap.add_argument("--out", help="output file (default odds/week<N>.json)")
    a = ap.parse_args()

    key = os.environ.get("ODDS_API_KEY")
    if not key:
        sys.exit("Set ODDS_API_KEY in your environment first.")
    if a.all:
        start, end, label = datetime.now(timezone.utc).replace(microsecond=0), None, "upcoming"
    elif a.days:
        start = datetime.now(timezone.utc).replace(microsecond=0)
        end, label = start + timedelta(days=a.days), f"next{a.days}d"
    else:
        a.week = a.week or current_week()
        (start, end), label = week_window(a.week), f"week{a.week}"
    games, left = {}, None
    for lg in [x.strip().lower() for x in a.leagues.split(",") if x.strip()]:
        if lg not in SPORTS:
            sys.exit(f"Unknown league {lg!r}; use {', '.join(SPORTS)}")
        events, left = fetch(SPORTS[lg], key, start, end, a.region)
        n = 0
        for ev in events:
            g, why = to_game(ev, lg, a.book)
            if g:
                games[f"{lg}-{ev['id']}"] = g
                n += 1
            else:
                print(f"  skip {lg} {ev['away_team']} @ {ev['home_team']}: {why}", file=sys.stderr)
        print(f"{lg.upper()}: {n} games", file=sys.stderr)

    out = Path(a.out) if a.out else Path(__file__).resolve().parent.parent / "odds" / f"{label}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(games, indent=2, sort_keys=True) + "\n")
    print(f"{label} ({iso(start)} to {iso(end) if end else 'whenever'}): wrote {len(games)} games to {out}", file=sys.stderr)
    if left is not None:
        print(f"Odds API credits left: {left}", file=sys.stderr)


if __name__ == "__main__":
    main()
