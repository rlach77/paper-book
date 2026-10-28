#!/usr/bin/env python3
"""Build dev/preview.html: the real index.html with supabase-js and config.js swapped for the local mock
(dev/mock-supabase.js) and seed/games.json, so the app runs without a Supabase project.

    python3 scripts/build_preview.py && python3 -m http.server 8000
    open http://localhost:8000/dev/preview.html                       (you, as admin)
    open http://localhost:8000/dev/preview.html?as=u_friend&owner=0   (a friend, in another tab)
    add &reset=1 to wipe the mock data, &as=none to see it signed out
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
page = (root / "index.html").read_text()
real = ['<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>',
        '<script src="config.js"></script>']
for tag in real:
    assert tag in page, f"index.html no longer contains {tag!r}; update build_preview.py"
mock = (f'<script>window.__PAPERBOOK_SEED__ = {(root / "seed/games.json").read_text()};</script>\n'
        f'<script>{(root / "dev/mock-supabase.js").read_text()}</script>')
page = page.replace(real[0], mock).replace(real[1] + "\n", "")
(root / "dev/preview.html").write_text(page)
print("Wrote dev/preview.html")
