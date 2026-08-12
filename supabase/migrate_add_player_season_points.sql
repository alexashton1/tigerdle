-- Run this once in the Supabase SQL editor. Aggregates each player's
-- total points contributed to predictors this season, pulled from the
-- detailed breakdown already recorded by calculate_fixture_scores(),
-- not a new tracking system. Used to show and sort players by season
-- points in the Predictor's team picker.
--
-- IMPORTANT: this only works correctly for fixtures scored AFTER the
-- player_id fix went into calculate_fixture_scores() (see
-- migrate_add_scoring_system.sql). If you've already scored fixtures
-- before that fix, re-run "Calculate scores" on them in admin once,
-- it's safe to re-run, and it'll backfill the missing player_id.

create or replace view player_season_points
with (security_invoker = true) as
with position_pts as (
  select (elem->>'player_id')::uuid as player_id, 2 as points
  from prediction_scores ps, jsonb_array_elements(ps.breakdown->'correct_positions') elem
),
predicted_scorer_pts as (
  select
    (ps.breakdown->'predicted_scorer'->>'player_id')::uuid as player_id,
    (ps.breakdown->'predicted_scorer'->>'points')::int as points
  from prediction_scores ps
  where ps.breakdown->'predicted_scorer'->>'hit' = 'true'
    and ps.breakdown->'predicted_scorer'->>'player_id' is not null
),
first_scorer_pts as (
  select
    (ps.breakdown->'first_scorer'->>'player_id')::uuid as player_id,
    (ps.breakdown->'first_scorer'->>'points')::int as points
  from prediction_scores ps
  where ps.breakdown->'first_scorer'->>'hit' = 'true'
    and ps.breakdown->'first_scorer'->>'player_id' is not null
),
all_pts as (
  select * from position_pts
  union all select * from predicted_scorer_pts
  union all select * from first_scorer_pts
)
select player_id, sum(points)::int as season_points
from all_pts
where player_id is not null
group by player_id;

grant select on player_season_points to anon, authenticated;
