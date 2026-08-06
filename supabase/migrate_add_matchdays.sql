-- Run this once in the Supabase SQL editor. Adds a table to record each
-- matchday's lineup, formation, ratings, and opponent — safe to run even
-- if you're not sure whether it's already been applied.

create table if not exists matchdays (
  id uuid primary key default gen_random_uuid(),
  match_date date not null,
  opponent text not null,
  competition text,
  home_away text check (home_away in ('Home','Away')),
  hull_score int,
  opponent_score int,
  formation text not null,
  -- Array of { player_id, first_name, last_name, slot, is_sub, rating }
  -- Storing names alongside player_id means the lineup still displays
  -- correctly even if a player is later deactivated or renamed.
  lineup jsonb not null default '[]'::jsonb,
  -- Guards against double-counting appearances if a matchday gets edited
  -- after being saved — tracks exactly which players have already had
  -- an appearance credited for this specific matchday.
  appearances_counted_for jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table matchdays enable row level security;

drop policy if exists "public read matchdays" on matchdays;
create policy "public read matchdays" on matchdays
  for select using (true);
-- No write policies for anon — all writes go through admin-action.

create index if not exists matchdays_date_idx on matchdays(match_date desc);
