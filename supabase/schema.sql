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
drop policy if exists "players: join as yourself" on public.players;
create policy "players: join as yourself" on public.players for insert to authenticated
  with check (id = auth.uid() or public.is_admin());
drop policy if exists "players: edit yourself" on public.players;
create policy "players: edit yourself" on public.players for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
drop policy if exists "players: admins delete" on public.players;
create policy "players: admins delete" on public.players for delete to authenticated using (public.is_admin());

drop policy if exists "admins: read own" on public.admins;
create policy "admins: read own" on public.admins for select to authenticated using (user_id = auth.uid());

-- ---------- server-side pick rules ----------
-- Any ticket that is added, changed or removed must only touch games that haven't started, aren't final
-- and aren't locked; new tickets must reference real games. (Bankroll limits are still checked in the page.)
create or replace function public.check_bets() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  b jsonb;
  leg jsonb;
  is_new boolean;
begin
  if public.is_admin() then return new; end if;
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
