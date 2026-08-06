-- Run this once in the Supabase SQL editor. Adds a table for the real
-- fixture list — Premier League fixtures for 2026-27, entered/adjusted
-- by you. Safe to run even if already applied.

create table if not exists fixtures (
  id uuid primary key default gen_random_uuid(),
  opponent text not null,
  match_date date not null,
  kickoff_time text,
  competition text,
  home_away text check (home_away in ('Home','Away')),
  status text not null default 'Scheduled' check (status in ('Scheduled','Completed','Postponed')),
  created_at timestamptz not null default now()
);

alter table fixtures enable row level security;

drop policy if exists "public read fixtures" on fixtures;
create policy "public read fixtures" on fixtures
  for select using (true);

create index if not exists fixtures_date_idx on fixtures(match_date);
