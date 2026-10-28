// Local stand-in for supabase-js (`window.supabase.createClient`), covering only what Paper Book uses.
// Rows live in localStorage, so two tabs on the same origin behave like two signed-in friends.
// Access rules and the pick-lock trigger from supabase/schema.sql are NOT enforced here; the line_history
// trigger is imitated (a row whenever a game's lines change).
//
// URL params:  ?as=<userId>   be that user (default "u_dev_owner"); "none" = signed out
//              &invite=dev-invite   arrive by invite link (needed to join as a non-admin)
//              &owner=0       not an admin (no "Run the book" tab)
//              &reset=1       wipe the mock store and reseed games from seed/games.json
(function () {
  const params = new URLSearchParams(location.search);
  const KEY = 'paperbook-mock-supabase';
  const as = params.get('as') || 'u_dev_owner';
  const isAdmin = params.get('owner') !== '0';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY)); } catch { return null; } };
  const save = s => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch {} };

  let db = params.get('reset') === '1' ? null : load();
  if (!db) {
    db = { games: {}, players: {}, line_history: {}, signedOut: {} };
    for (const [id, g] of Object.entries(window.__PAPERBOOK_SEED__ || {})) { db.games[id] = toSnake({ id, ...g }); recordLines(db.games[id], null); }
    demoMoves();
    save(db);
  }
  function toSnake(g) {
    const map = { startsAt: 'starts_at', awayML: 'away_ml', homeML: 'home_ml', homeSpread: 'home_spread', spreadOdds: 'spread_odds', awaySpreadOdds: 'away_spread_odds', totalOdds: 'total_odds', underOdds: 'under_odds' };
    return Object.fromEntries(Object.entries(g).map(([k, v]) => [map[k] || k, v]));
  }
  const clone = x => JSON.parse(JSON.stringify(x));
  // Made-up earlier lines for a few seed games, so the preview shows line-move charts right away.
  function demoMoves() {
    const toOdds = p => p >= 0.5 ? -Math.round(100 * p / (1 - p)) : Math.round(100 * (1 - p) / p);
    const prob = o => o < 0 ? -o / (-o + 100) : 100 / (o + 100);
    const ids = Object.keys(db.games).slice(0, 3);
    ids.forEach((gid, n) => {
      const g = db.games[gid], cur = Object.values(db.line_history).find(h => h.game_id === gid);
      cur.at = new Date(Date.now() - 2 * 3600e3).toISOString();
      [3, 1.5].forEach((days, k) => {
        const step = 2 - k, id = 'demo-' + gid + '-' + k;   // 2 steps back, then 1
        db.line_history[id] = { id, game_id: gid, at: new Date(Date.now() - days * 864e5).toISOString(),
          away_ml: toOdds(prob(g.away_ml) + 0.025 * step), home_ml: toOdds(prob(g.home_ml) - 0.025 * step),
          home_spread: g.home_spread + 0.5 * step, spread_odds: g.spread_odds,
          total: n === 1 ? g.total : g.total - 0.5 * step, total_odds: g.total_odds };
      });
    });
  }
  function recordLines(g, before) {
    const LINES = ['away_ml', 'home_ml', 'home_spread', 'spread_odds', 'total', 'total_odds'];
    if (before && LINES.every(k => before[k] === g[k])) return;
    const id = String(Object.keys(db.line_history ||= {}).length + 1);
    db.line_history[id] = { id, game_id: g.id, at: new Date().toISOString(), ...Object.fromEntries(LINES.map(k => [k, g[k] ?? null])) };
  }

  // realtime: diff the store on every change (this tab or another) and emit postgres_changes-style events
  const listeners = [];
  let last = clone(db);
  function emit() {
    for (const table of ['games', 'players', 'line_history']) {
      const before = last[table] || {}, after = db[table] || {};
      for (const id of new Set([...Object.keys(before), ...Object.keys(after)])) {
        const a = before[id], b = after[id];
        if (JSON.stringify(a) === JSON.stringify(b)) continue;
        const ev = !a ? { eventType: 'INSERT', new: clone(b), old: {} } : !b ? { eventType: 'DELETE', new: {}, old: { id } } : { eventType: 'UPDATE', new: clone(b), old: { id } };
        listeners.filter(l => l.table === table).forEach(l => setTimeout(() => l.fn(ev), 0));
      }
    }
    last = clone(db);
  }
  window.addEventListener('storage', e => { if (e.key === KEY) { db = load() || db; emit(); } });
  const commit = () => { save(db); emit(); };

  class Query {
    constructor(table) { this.table = table; this.op = 'select'; this.filters = []; this.ret = false; }
    select() { if (this.op !== 'select') this.ret = true; return this; }
    insert(rows) { this.op = 'insert'; this.rows = [].concat(rows); return this; }
    update(patch) { this.op = 'update'; this.patch = patch; return this; }
    delete() { this.op = 'delete'; return this; }
    eq(c, v) { this.filters.push(r => r[c] === v); return this; }
    in(c, vs) { this.filters.push(r => vs.includes(r[c])); return this; }
    gte(c, v) { this.filters.push(r => r[c] >= v); return this; }
    order(c) { this.sort = c; return this; }
    range(a, b) { this.rng = [a, b]; return this; }
    then(ok, bad) { return Promise.resolve().then(() => this.run()).then(ok, bad); }
    run() {
      const t = db[this.table] ||= {};
      const match = () => Object.values(t).filter(r => this.filters.every(f => f(r)));
      if (this.op === 'insert') {
        const out = [];
        for (const r of this.rows) {
          const id = r.id || Math.random().toString(36).slice(2, 12);
          if (t[id]) return { data: null, error: { code: '23505', message: 'duplicate key' } };
          t[id] = { ...(this.table === 'games' ? { final: null, locked: false } : { joined_at: new Date().toISOString(), bets: [] }), ...clone(r), id };
          out.push(clone(t[id]));
          if (this.table === 'games') recordLines(t[id], null);
        }
        commit(); return { data: this.ret ? out : null, error: null };
      }
      if (this.op === 'update') {
        const rows = match(); rows.forEach(r => { const before = clone(r); Object.assign(r, clone(this.patch)); if (this.table === 'games') recordLines(r, before); }); commit();
        return { data: this.ret ? clone(rows) : null, error: null };
      }
      if (this.op === 'delete') {
        const rows = match(); rows.forEach(r => delete t[r.id]); commit();
        return { data: this.ret ? clone(rows) : null, error: null };
      }
      let rows = match();
      if (this.sort) rows.sort((a, b) => String(a[this.sort]).localeCompare(String(b[this.sort])));
      if (this.rng) rows = rows.slice(this.rng[0], this.rng[1] + 1);
      return { data: clone(rows), error: null };
    }
  }

  const authCbs = [];
  const session = () => (as === 'none' || db.signedOut[as]) ? null : { user: { id: as, user_metadata: { full_name: as === 'u_dev_owner' ? 'Ryan Dev' : as.replace(/^u_/, '') + ' Friend' } } };
  const client = {
    from: table => new Query(table),
    // invite code is "dev-invite" (open dev/preview.html?invite=dev-invite&as=u_friend&owner=0 to join as a friend)
    rpc: async (name, args = {}) => {
      if (name === 'is_admin') return { data: !!session() && isAdmin, error: null };
      if (name === 'invite_code') return isAdmin ? { data: db.invite = args.p_rotate ? Math.random().toString(36).slice(2, 10) : (db.invite || 'dev-invite'), error: null } : { data: null, error: { code: '42501' } };
      if (name === 'join_book') {
        if (!session()) return { data: null, error: { hint: 'signed_out' } };
        if (!isAdmin && args.p_code !== (db.invite || 'dev-invite')) return { data: null, error: { hint: 'bad_invite', message: 'invite code is wrong' } };
        if (Object.values(db.players).some(p => p.id !== as && p.handle.trim().toLowerCase() === args.p_handle.trim().toLowerCase())) return { data: null, error: { code: '23505', message: 'players_handle_unique' } };
        db.players[as] ||= { id: as, handle: args.p_handle.trim(), joined_at: new Date().toISOString(), bets: [] };
        commit(); return { data: [clone(db.players[as])], error: null };
      }
      return { data: null, error: null };
    },
    channel: () => {
      const ch = { on(_, filter, fn) { listeners.push({ table: filter.table, fn }); return ch; }, subscribe() { return ch; } };
      return ch;
    },
    auth: {
      initialize: async () => ({ error: null }),
      exchangeCodeForSession: async () => ({ data: { session: session() }, error: null }),
      getSession: async () => ({ data: { session: session() } }),
      onAuthStateChange: fn => { authCbs.push(fn); return { data: { subscription: { unsubscribe() {} } } }; },
      signInWithOAuth: async () => { delete db.signedOut[as]; save(db); authCbs.forEach(fn => fn('SIGNED_IN', session())); return { error: null }; },
      signOut: async () => { db.signedOut[as] = true; save(db); authCbs.forEach(fn => fn('SIGNED_OUT', null)); return { error: null }; }
    }
  };
  window.supabase = { createClient: () => client };
  window.PAPERBOOK = { supabaseUrl: 'mock://local', supabaseKey: 'mock' };
  console.info(`[mock-supabase] signed in as ${as}${isAdmin ? ' (admin)' : ''}`);
})();
