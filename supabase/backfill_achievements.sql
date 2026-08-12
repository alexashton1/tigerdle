-- Run this once in the Supabase SQL editor, AFTER both
-- migrate_add_achievements.sql and migrate_add_more_achievements.sql
-- have already been run. Retroactively checks every existing user
-- against the current achievement definitions, so nobody has to wait
-- for their next sign-in to get credit for progress they already have.
--
-- Safe to run more than once, calculate_achievements() only ever adds
-- newly-earned achievements, never removes or duplicates existing ones.

do $$
declare
  u record;
  checked_count int := 0;
begin
  -- Anyone with either game stats or a prediction/league history,
  -- covers everyone who could possibly have earned anything, without
  -- running the check pointlessly for auth.users rows with no activity.
  for u in
    select distinct user_id from (
      select user_id from user_stats
      union
      select user_id from prediction_scores
      union
      select user_id from league_members
    ) all_active_users
  loop
    perform calculate_achievements(u.user_id);
    checked_count := checked_count + 1;
  end loop;

  raise notice 'Backfilled achievements for % users.', checked_count;
end $$;
