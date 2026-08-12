-- Run this once in the Supabase SQL editor. This is the predictions
-- core, the next phase after accounts. Leagues and points scoring are
-- NOT in this migration; they're a separate phase once this is working
-- and tested, since a scoring bug affecting real friends matters more
-- to get right than almost anything else here.

create table if not exists predictions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fixture_id uuid not null references fixtures(id) on delete cascade,
  formation text not null,
  -- [{player_id, first_name, last_name, slot}]
  lineup jsonb not null default '[]'::jsonb,
  hull_score int,
  opponent_score int,
  -- [{player_id, first_name, last_name}]
  scorers jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  unique(user_id, fixture_id)
);

alter table predictions enable row level security;

-- A prediction is only ever readable/writable by the person who made
-- it. Nobody else, including other signed-in users, can query someone
-- else's specific pick through this table. The aggregate views below
-- are the only sanctioned way anyone sees "what other people predicted",
-- and they only ever expose counts, never who predicted what.
drop policy if exists "users read own predictions" on predictions;
create policy "users read own predictions" on predictions
  for select using (auth.uid() = user_id);

-- Locking: a fixture stops accepting new or changed predictions once
-- it's kicked off. Enforced here, server-side, not just hidden in the
-- UI. A direct API call after kickoff is rejected by the database
-- itself, not just discouraged by the frontend.
create or replace function fixture_not_started(fid uuid) returns boolean as $$
  select coalesce(
    (select (match_date + coalesce(kickoff_time, '00:00')::time) > now()
     from fixtures where id = fid),
    false
  );
$$ language sql stable;

drop policy if exists "users insert own predictions before kickoff" on predictions;
create policy "users insert own predictions before kickoff" on predictions
  for insert with check (auth.uid() = user_id and fixture_not_started(fixture_id));

drop policy if exists "users update own predictions before kickoff" on predictions;
create policy "users update own predictions before kickoff" on predictions
  for update using (auth.uid() = user_id and fixture_not_started(fixture_id));

-- ---------- aggregate views: "most predicted XI" as percentages ----------
-- Each of these only ever returns counts grouped by fixture, never a
-- user_id, never which specific person picked what. That's what makes
-- it safe to expose to any visitor, signed in or not.

create or replace view prediction_slot_counts as
select
  p.fixture_id,
  lineup_item.slot,
  lineup_item.player_id,
  lineup_item.first_name,
  lineup_item.last_name,
  count(*) as votes
from predictions p,
  jsonb_to_recordset(p.lineup) as lineup_item(player_id uuid, first_name text, last_name text, slot text)
group by p.fixture_id, lineup_item.slot, lineup_item.player_id, lineup_item.first_name, lineup_item.last_name;

grant select on prediction_slot_counts to anon, authenticated;

create or replace view prediction_formation_counts as
select fixture_id, formation, count(*) as votes
from predictions
group by fixture_id, formation;

grant select on prediction_formation_counts to anon, authenticated;

create or replace view prediction_score_counts as
select fixture_id, hull_score, opponent_score, count(*) as votes
from predictions
where hull_score is not null and opponent_score is not null
group by fixture_id, hull_score, opponent_score;

grant select on prediction_score_counts to anon, authenticated;

create or replace view prediction_scorer_counts as
select
  p.fixture_id,
  scorer_item.type,
  scorer_item.player_id,
  scorer_item.first_name,
  scorer_item.last_name,
  count(*) as votes
from predictions p,
  jsonb_to_recordset(p.scorers) as scorer_item(player_id uuid, first_name text, last_name text, type text)
group by p.fixture_id, scorer_item.type, scorer_item.player_id, scorer_item.first_name, scorer_item.last_name;

grant select on prediction_scorer_counts to anon, authenticated;

create or replace view prediction_totals as
select fixture_id, count(*) as total_predictions
from predictions
group by fixture_id;

grant select on prediction_totals to anon, authenticated;

-- One honest limitation worth knowing: kickoff locking compares against
-- the database's UTC clock, while kickoff_time is entered as plain UK
-- local time (e.g. "15:00"). This is off by an hour during British
-- Summer Time. Not a problem in practice, predictions realistically
-- close well before kickoff anyway, but worth knowing if you ever see
-- locking behave an hour earlier/later than expected in summer.
