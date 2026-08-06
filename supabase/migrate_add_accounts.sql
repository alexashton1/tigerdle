-- Run this once in the Supabase SQL editor. This is the accounts
-- foundation — separate from everything else on the site, which stays
-- completely login-free. Only user_stats exists so far (syncing the
-- streaks/stats the games already track locally); predictor tables come
-- in a later phase, once this is confirmed working.

-- Auth itself needs no table — Supabase Auth manages auth.users for you.
-- You do need to turn on Email auth in the dashboard: Authentication →
-- Providers → Email → make sure it's enabled (it usually is by default).
-- Magic link sign-in needs no extra setup beyond that.

create table if not exists user_stats (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- { m1: {played, wins, streak, maxStreak}, m2: {...}, m3: {...}, m4: {...} }
  stats jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table user_stats enable row level security;

-- Real per-row security: a signed-in user can only ever read or write
-- their own stats row, enforced by the database itself — not just by
-- what the frontend chooses to ask for.
drop policy if exists "users read own stats" on user_stats;
create policy "users read own stats" on user_stats
  for select using (auth.uid() = user_id);

drop policy if exists "users insert own stats" on user_stats;
create policy "users insert own stats" on user_stats
  for insert with check (auth.uid() = user_id);

drop policy if exists "users update own stats" on user_stats;
create policy "users update own stats" on user_stats
  for update using (auth.uid() = user_id);
