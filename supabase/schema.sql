-- Paper Book schema. Run once in the Supabase SQL editor (Dashboard → SQL Editor → New query).
-- Re-running is safe: everything is create-if-missing / create-or-replace.

-- ---------- tables ----------
create table if not exists public.games (
  id               text primary key default gen_random_uuid()::text,
  league           text not null default 'NFL',      -- first word is the league key ("NFL · Madrid" ok)
  week             int  not null,                    -- book week (Tue→Mon on the NFL calendar)
  away             text not null,
  home             text not null,
  starts_at        timestamptz not null,             -- picks lock at this time
  away_ml          int  not null,
  home_ml          int  not null,
  home_spread      numeric not null,                 -- away spread is the negation
  spread_odds      int  not null default -110,       -- home spread price
  away_spread_odds int,                              -- null = same as spread_odds
  total            numeric not null,
  total_odds       int  not null default -110,       -- over price
  under_odds       int,                              -- null = same as total_odds
  final            jsonb,                            -- { "away": 24, "home": 27 } settles every pick
  locked           boolean not null default false,   -- manual early lock
  source           text,                             -- e.g. "odds-api:draftkings"
  updated_at       timestamptz not null default now()
);
create index if not exists games_starts_at on public.games (starts_at);

create table if not exists public.players (
  id         uuid primary key references auth.users (id) on delete cascade,
  handle     text not null check (char_length(handle) between 2 and 20),
  joined_at  timestamptz not null default now(),
  bets       jsonb not null default '[]'::jsonb      -- same shape as before: straights and { market: "parlay", legs: [...] }
);

-- commissioners: whoever is listed here gets the "Run the book" tab and can write games
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- access rules ----------
alter table public.games   enable row level security;
alter table public.players enable row level security;
alter table public.admins  enable row level security;

drop policy if exists "games: anyone reads" on public.games;
create policy "games: anyone reads" on public.games for select using (true);
drop policy if exists "games: admins write" on public.games;
create policy "games: admins write" on public.games for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "players: anyone reads" on public.players;
create policy "players: anyone reads" on public.players for select using (true);
-- players join through join_book() (needs the invite code); only admins insert rows directly
drop policy if exists "players: join as yourself" on public.players;
drop policy if exists "players: admins insert" on public.players;
create policy "players: admins insert" on public.players for insert to authenticated with check (public.is_admin());
drop policy if exists "players: edit yourself" on public.players;
create policy "players: edit yourself" on public.players for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
drop policy if exists "players: admins delete" on public.players;
create policy "players: admins delete" on public.players for delete to authenticated using (public.is_admin());

drop policy if exists "admins: read own" on public.admins;
create policy "admins: read own" on public.admins for select to authenticated using (user_id = auth.uid());

-- ---------- server-side pick rules ----------
-- The page checks all of this too; these keep someone writing to the API directly honest.
-- Every ticket that is added, changed or removed must only touch games that haven't started, aren't final and
-- aren't locked. A new ticket must also: reference real games; price every leg at the game's current line and
-- odds; keep a parlay to 2–8 legs, one per market per game, one week, and no ML + other side's spread ≤ 0; and
-- fit the player's units left that week (1,000 + net of settled picks − stakes on open picks, same as the page).
-- Admins editing someone else's row, and the SQL editor / service role (no auth.uid()), skip these checks.

-- decimal odds from American odds
create or replace function public.dec_odds(o numeric) returns numeric
language sql immutable as $$ select case when o > 0 then 1 + o / 100 else 1 + 100 / abs(o) end $$;

-- one leg against its game: 'won' | 'lost' | 'push' | 'pending' (same as grade() in the page)
create or replace function public.grade_leg(leg jsonb, g public.games) returns text
language sql stable as $$
  select case when g.final is null then 'pending' else
    case sign(case leg->>'market'
      when 'ml' then case leg->>'side' when 'home' then (g.final->>'home')::numeric - (g.final->>'away')::numeric
                                          else (g.final->>'away')::numeric - (g.final->>'home')::numeric end
      when 'spread' then case leg->>'side' when 'home' then (g.final->>'home')::numeric + (leg->>'line')::numeric - (g.final->>'away')::numeric
                                              else (g.final->>'away')::numeric + (leg->>'line')::numeric - (g.final->>'home')::numeric end
      else case leg->>'side' when 'over' then (g.final->>'away')::numeric + (g.final->>'home')::numeric - (leg->>'line')::numeric
                             else (leg->>'line')::numeric - (g.final->>'away')::numeric - (g.final->>'home')::numeric end
    end) when 1 then 'won' when -1 then 'lost' else 'push' end end
$$;

-- a ticket's result and net, and its book week (same as outcome() / betWeek() in the page)
create or replace function public.ticket_outcome(b jsonb, out r text, out net numeric, out week int)
language plpgsql stable set search_path = public as $$
declare
  leg jsonb; g games; res text;
  won numeric := 1; live int := 0; pending boolean := false; lost boolean := false;
begin
  week := nullif(b->>'week', '')::int;
  for leg in select l from jsonb_array_elements(case when b->>'market' = 'parlay' then coalesce(b->'legs', '[]') else jsonb_build_array(b) end) l loop
    select * into g from games where id = leg->>'gameId';
    if not found then continue; end if;          -- leg on a deleted game: void
    live := live + 1; week := coalesce(week, g.week);
    res := grade_leg(leg, g);
    if res = 'lost' then lost := true; elsif res = 'pending' then pending := true; elsif res = 'won' then won := won * dec_odds((leg->>'odds')::numeric); end if;
  end loop;
  if live = 0 then r := 'void'; net := 0;
  elsif lost then r := 'lost'; net := -(b->>'stake')::numeric;
  elsif pending then r := 'pending'; net := 0;
  elsif won > 1 then r := 'won'; net := (b->>'stake')::numeric * (won - 1);
  else r := 'push'; net := 0; end if;
end;
$$;

-- validates one new ticket (raises with hint bad_bet / line_moved / clash / game_missing); returns its week
create or replace function public.check_new_ticket(b jsonb) returns int
language plpgsql stable set search_path = public as $$
declare
  legs jsonb; leg jsonb; g games; n int; wk int; want_odds numeric; want_line numeric; seen text[] := '{}'; k text;
begin
  if coalesce(b->>'id', '') = '' or jsonb_typeof(b->'stake') is distinct from 'number' or (b->>'stake')::numeric <= 0 then
    raise exception 'bad ticket' using errcode = 'P0001', hint = 'bad_bet';
  end if;
  legs := case when b->>'market' = 'parlay' then b->'legs' else jsonb_build_array(b) end;
  if jsonb_typeof(legs) is distinct from 'array' then raise exception 'bad ticket' using errcode = 'P0001', hint = 'bad_bet'; end if;
  n := jsonb_array_length(legs);
  if b->>'market' = 'parlay' and (n < 2 or n > 8) then raise exception 'parlays need 2–8 legs' using errcode = 'P0001', hint = 'bad_bet'; end if;
  for leg in select l from jsonb_array_elements(legs) l loop
    select * into g from games where id = leg->>'gameId';
    if not found then raise exception 'unknown game %', leg->>'gameId' using errcode = 'P0001', hint = 'game_missing'; end if;
    k := (leg->>'gameId') || '/' || (leg->>'market');
    if k = any(seen) then raise exception 'two legs on one market' using errcode = 'P0001', hint = 'bad_bet'; end if;
    seen := seen || k;
    if wk is null then wk := g.week; elsif wk <> g.week then raise exception 'parlay spans weeks' using errcode = 'P0001', hint = 'bad_bet'; end if;
    case (leg->>'market') || ':' || (leg->>'side')
      when 'ml:home'     then want_odds := g.home_ml; want_line := null;
      when 'ml:away'     then want_odds := g.away_ml; want_line := null;
      when 'spread:home' then want_odds := g.spread_odds; want_line := g.home_spread;
      when 'spread:away' then want_odds := coalesce(g.away_spread_odds, g.spread_odds); want_line := -g.home_spread;
      when 'total:over'  then want_odds := g.total_odds; want_line := g.total;
      when 'total:under' then want_odds := coalesce(g.under_odds, g.total_odds); want_line := g.total;
      else raise exception 'bad market' using errcode = 'P0001', hint = 'bad_bet';
    end case;
    if (leg->>'odds')::numeric is distinct from want_odds or (leg->>'line')::numeric is distinct from want_line then
      raise exception 'line moved on %', leg->>'gameId' using errcode = 'P0001', hint = 'line_moved';
    end if;
  end loop;
  if n > 1 and exists (select 1 from jsonb_array_elements(legs) a, jsonb_array_elements(legs) sp
      where a->>'gameId' = sp->>'gameId' and a->>'market' = 'ml' and sp->>'market' = 'spread'
        and a->>'side' <> sp->>'side' and (sp->>'line')::numeric <= 0) then
    raise exception 'those legs can''t both win' using errcode = 'P0001', hint = 'clash';
  end if;
  if nullif(b->>'week', '') is not null and (b->>'week')::int <> wk then raise exception 'wrong week' using errcode = 'P0001', hint = 'bad_bet'; end if;
  return wk;
end;
$$;

create or replace function public.check_bets() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  b jsonb; leg jsonb; is_new boolean; weeks int[] := '{}'; wk int; avail numeric;
begin
  if auth.uid() is null or (public.is_admin() and new.id <> auth.uid()) then return new; end if;
  if jsonb_typeof(coalesce(new.bets, '[]')) <> 'array'
     or (select count(*) <> count(distinct x->>'id') from jsonb_array_elements(coalesce(new.bets, '[]')) x) then
    raise exception 'bad tickets' using errcode = 'P0001', hint = 'bad_bet';
  end if;
  for b, is_new in
    select x, true from jsonb_array_elements(coalesce(new.bets, '[]'::jsonb)) x
      where tg_op = 'INSERT' or not exists (select 1 from jsonb_array_elements(coalesce(old.bets, '[]'::jsonb)) y where y = x)
    union all
    select y, false from jsonb_array_elements(case when tg_op = 'UPDATE' then coalesce(old.bets, '[]'::jsonb) else '[]'::jsonb end) y
      where not exists (select 1 from jsonb_array_elements(coalesce(new.bets, '[]'::jsonb)) x where x = y)
  loop
    for leg in select l from jsonb_array_elements(case when b->>'market' = 'parlay' then b->'legs' else jsonb_build_array(b) end) l loop
      if is_new and not exists (select 1 from games g where g.id = leg->>'gameId') then
        raise exception 'unknown game %', leg->>'gameId' using errcode = 'P0001', hint = 'game_missing';
      end if;
      if exists (select 1 from games g where g.id = leg->>'gameId'
                 and (g.starts_at <= now() or g.locked or g.final is not null)) then
        raise exception 'game % has started', leg->>'gameId' using errcode = 'P0001', hint = 'game_started';
      end if;
    end loop;
    if is_new then weeks := weeks || public.check_new_ticket(b); end if;
  end loop;
  foreach wk in array weeks loop
    select 1000 + coalesce(sum(o.net) filter (where o.r in ('won', 'lost', 'push')), 0)
                - coalesce(sum((x->>'stake')::numeric) filter (where o.r = 'pending'), 0)
      into avail
      from jsonb_array_elements(new.bets) x, lateral public.ticket_outcome(x) o
      where o.week = wk;
    if avail < -0.005 then
      raise exception 'over the week % bankroll by %', wk, round(-avail, 2) using errcode = 'P0001', hint = 'over_bankroll';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists players_check_bets on public.players;
create trigger players_check_bets before insert or update of bets on public.players
  for each row execute function public.check_bets();

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists games_touch on public.games;
create trigger games_touch before update on public.games for each row execute function public.touch_updated_at();

-- ---------- invites and display names ----------
-- Joining needs the invite code (in the link the commissioner shares: ?invite=<code>); admins can join without one.
-- The code lives in settings, which has no policies, so only these security-definer functions can read it.
create table if not exists public.settings (key text primary key, value text not null);
alter table public.settings enable row level security;
insert into public.settings (key, value) values ('invite_code', substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
  on conflict (key) do nothing;

create or replace function public.join_book(p_handle text, p_code text default null) returns setof public.players
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = 'P0001', hint = 'signed_out'; end if;
  if not public.is_admin() and p_code is distinct from (select value from settings where key = 'invite_code') then
    raise exception 'invite code is wrong or was replaced' using errcode = 'P0001', hint = 'bad_invite';
  end if;
  return query insert into players (id, handle) values (auth.uid(), btrim(p_handle))
    on conflict (id) do update set handle = players.handle returning *;
end;
$$;

-- the current invite code (p_rotate = true makes a new one, so old links stop working); admins only
create or replace function public.invite_code(p_rotate boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if p_rotate then update settings set value = substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) where key = 'invite_code'; end if;
  select value into v from settings where key = 'invite_code';
  return v;
end;
$$;

revoke execute on function public.join_book(text, text) from public, anon;
revoke execute on function public.invite_code(boolean) from public, anon;
grant execute on function public.join_book(text, text) to authenticated;
grant execute on function public.invite_code(boolean) to authenticated;

-- display names are unique, ignoring case and surrounding spaces
create unique index if not exists players_handle_unique on public.players (lower(btrim(handle)));

-- ---------- line history ----------
-- One row per distinct set of lines a game has had (written by trigger on insert and on any line change,
-- whether from the daily odds pull or the commissioner). The page draws line-move charts from it.
create table if not exists public.line_history (
  id          bigint generated always as identity primary key,
  game_id     text not null references public.games (id) on delete cascade,
  at          timestamptz not null default now(),
  away_ml     int,
  home_ml     int,
  home_spread numeric,
  spread_odds int,
  total       numeric,
  total_odds  int
);
create index if not exists line_history_game on public.line_history (game_id, at);
alter table public.line_history enable row level security;
drop policy if exists "line_history: anyone reads" on public.line_history;
create policy "line_history: anyone reads" on public.line_history for select using (true);

create or replace function public.record_lines() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or (new.away_ml, new.home_ml, new.home_spread, new.spread_odds, new.total, new.total_odds)
       is distinct from (old.away_ml, old.home_ml, old.home_spread, old.spread_odds, old.total, old.total_odds) then
    insert into line_history (game_id, away_ml, home_ml, home_spread, spread_odds, total, total_odds)
    values (new.id, new.away_ml, new.home_ml, new.home_spread, new.spread_odds, new.total, new.total_odds);
  end if;
  return new;
end;
$$;
drop trigger if exists games_record_lines on public.games;
create trigger games_record_lines after insert or update on public.games
  for each row execute function public.record_lines();

-- ---------- live updates ----------
do $$ begin
  alter publication supabase_realtime add table public.games;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.players;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.line_history;
exception when duplicate_object then null; end $$;
