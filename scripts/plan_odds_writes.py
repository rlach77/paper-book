#!/usr/bin/env python3
"""Turn a fetch_odds.py pull into ArtifactData batch writes against the live `games` collection.

    python3 scripts/plan_odds_writes.py --odds odds/next3d.json \
        --live <dir of live game docs, one <id>.json each> --versions versions.json --out plan/

--live     the directory ArtifactData saved with out_dir (…/games/<id>.json): every game starting from
           24h ago on (query startsAt >= now - 24h), all leagues, so nothing the pull returns is missed.
--versions {"<id>": <version>} for those docs, copied from the ArtifactData listing.

Writes plan/batch-1.json, batch-2.json, … (≤50 writes each, the ArtifactData batch limit) whose entries point
at plan/docs/<id>.json via `file_path`, so each batch file can be passed to ArtifactData's `writes` as-is.
- new game id        -> set (full doc), unless a live doc already has the same home + away teams starting
                        within 36h (e.g. a hand-entered game): then that doc is treated as the match
- existing, open     -> update only the line fields that changed, pinned with if_version
- existing, started / final / locked, or starting within 15 min -> left alone
Results (`final`), manual locks and everyone's tickets are never touched.
"""
import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

LINE_FIELDS = ["startsAt", "week", "awayML", "homeML", "homeSpread", "spreadOdds", "awaySpreadOdds",
               "total", "totalOdds", "underOdds", "source"]
SOON = timedelta(minutes=15)
SAME_GAME = timedelta(hours=36)


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--odds", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--versions", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    odds = json.loads(Path(a.odds).read_text())
    versions = json.loads(Path(a.versions).read_text())
    live = {p.stem: json.loads(p.read_text()) for p in Path(a.live).glob("*.json")}
    now = datetime.now(timezone.utc)

    writes, new, changed, same, skipped = [], [], [], 0, []
    for gid, g in sorted(odds.items()):
        label = f"{g['league']} {g['away']} @ {g['home']}"
        if ts(g["startsAt"]) - now < SOON:
            skipped.append(f"{label} (starts within 15 min)")
            continue
        cur = live.get(gid)
        if cur is None:  # same matchup already on the board under another id (hand-entered)?
            twin = next((lid for lid, l in live.items() if lid not in odds and l.get("home") == g["home"]
                         and l.get("away") == g["away"] and abs(ts(l["startsAt"]) - ts(g["startsAt"])) <= SAME_GAME), None)
            if twin:
                gid, cur = twin, live[twin]
        if cur is None:
            writes.append(({"op": "set", "collection": "games", "doc_id": gid}, g))
            new.append(label)
            continue
        if cur.get("final") or cur.get("locked") or ts(cur["startsAt"]) <= now:
            skipped.append(f"{label} (started, final or locked)")
            continue
        if gid not in versions:
            raise SystemExit(f"No version for live doc {gid}; add it to {a.versions}")
        diff = {k: g.get(k) for k in LINE_FIELDS if g.get(k) != cur.get(k)}
        if not diff or set(diff) == {"source"}:
            same += 1
            continue
        writes.append(({"op": "update", "collection": "games", "doc_id": gid, "if_version": int(versions[gid])}, diff))
        changed.append(f"{label}: " + ", ".join(f"{k} {cur.get(k)}→{v}" for k, v in diff.items() if k != "source"))

    out = Path(a.out).resolve()
    docs = out / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    for old in [*out.glob("batch-*.json"), *docs.glob("*.json")]:
        old.unlink()
    entries = []
    for w, data in writes:
        f = docs / f"{w['doc_id']}.json"
        f.write_text(json.dumps(data, indent=2) + "\n")
        entries.append({**w, "file_path": str(f)})
    for i in range(0, len(entries), 50):
        (out / f"batch-{i // 50 + 1}.json").write_text(json.dumps(entries[i:i + 50]) + "\n")

    print(f"{len(new)} new, {len(changed)} line moves, {same} unchanged, {len(skipped)} skipped "
          f"-> {len(writes)} writes in {-(-len(writes) // 50)} batch file(s) under {out}")
    for x in new:
        print("  + " + x)
    for x in changed:
        print("  ~ " + x)
    for x in skipped:
        print("  - " + x)


if __name__ == "__main__":
    main()
