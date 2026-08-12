-- Run this once in the Supabase SQL editor, after migrate_add_achievements.sql
-- has already been run. Adds early "day one" achievements alongside more
-- long-term ones, so there's always something in reach whether someone
-- signed up yesterday or has been playing for months.

insert into achievement_definitions (key, category, name, icon, tier, description, points, sort_order) values
  -- TIGERDLE: a genuine first-win and a played-count ladder, on top of
  -- what already existed.
  ('tigerdle_first_bronze', 'TIGERDLE', 'First Word', '🔤', 'bronze', 'Win your first TIGERDLE', 10, 0),
  ('tigerdle_played_bronze', 'TIGERDLE', 'Regular Player', '📆', 'bronze', '10 played', 10, 8),
  ('tigerdle_played_silver', 'TIGERDLE', 'Regular Player', '📆', 'silver', '50 played', 40, 9),
  ('tigerdle_played_gold', 'TIGERDLE', 'Regular Player', '📆', 'gold', '150 played', 150, 9),

  -- Guess the Tiger: same early-win idea, plus a streak and a played
  -- ladder to match the pattern used everywhere else.
  ('tiger_first_bronze', 'Guess the Tiger', 'First Guess', '🎯', 'bronze', 'Win your first round', 10, 9),
  ('tiger_streak_bronze', 'Guess the Tiger', 'Tiger Streak', '🔥', 'bronze', '3-day streak', 15, 13),
  ('tiger_streak_silver', 'Guess the Tiger', 'Tiger Streak', '🔥', 'silver', '7-day streak', 40, 14),
  ('tiger_streak_gold', 'Guess the Tiger', 'Tiger Streak', '🔥', 'gold', '30-day streak', 120, 14),
  ('tiger_played_bronze', 'Guess the Tiger', 'Regular Player', '📆', 'bronze', '10 played', 10, 15),
  ('tiger_played_silver', 'Guess the Tiger', 'Regular Player', '📆', 'silver', '50 played', 40, 16),
  ('tiger_played_gold', 'Guess the Tiger', 'Regular Player', '📆', 'gold', '150 played', 150, 16),

  -- Mystery Tiger: a first win, a streak, and a win-count ladder, since
  -- it only had a played-count achievement before.
  ('mystery_first_bronze', 'Mystery Tiger', 'First Mystery', '🔍', 'bronze', 'Solve your first one', 10, 19),
  ('mystery_streak_bronze', 'Mystery Tiger', 'Mystery Streak', '🔥', 'bronze', '3-day streak', 15, 23),
  ('mystery_streak_silver', 'Mystery Tiger', 'Mystery Streak', '🔥', 'silver', '7-day streak', 40, 24),
  ('mystery_streak_gold', 'Mystery Tiger', 'Mystery Streak', '🔥', 'gold', '30-day streak', 120, 24),
  ('mystery_wins_bronze', 'Mystery Tiger', 'Mystery Wins', '🏅', 'bronze', '10 wins', 10, 25),
  ('mystery_wins_silver', 'Mystery Tiger', 'Mystery Wins', '🏅', 'silver', '50 wins', 40, 26),
  ('mystery_wins_gold', 'Mystery Tiger', 'Mystery Wins', '🏅', 'gold', '200 wins', 150, 26),

  -- Guess the Opponent: same pattern again.
  ('opponent_first_bronze', 'Guess the Opponent', 'First Guess', '⚽', 'bronze', 'Guess correctly for the first time', 10, 29),
  ('opponent_streak_bronze', 'Guess the Opponent', 'Opponent Streak', '🔥', 'bronze', '3-day streak', 15, 33),
  ('opponent_streak_silver', 'Guess the Opponent', 'Opponent Streak', '🔥', 'silver', '7-day streak', 40, 34),
  ('opponent_streak_gold', 'Guess the Opponent', 'Opponent Streak', '🔥', 'gold', '30-day streak', 120, 34),
  ('opponent_wins_bronze', 'Guess the Opponent', 'Opponent Wins', '🏅', 'bronze', '10 wins', 10, 35),
  ('opponent_wins_silver', 'Guess the Opponent', 'Opponent Wins', '🏅', 'silver', '50 wins', 40, 36),
  ('opponent_wins_gold', 'Guess the Opponent', 'Opponent Wins', '🏅', 'gold', '200 wins', 150, 36),

  -- Across all games: a genuine long-term ladder on top of the two
  -- that already existed, tracking total volume across everything.
  ('dedicated_bronze', 'Across all games', 'Dedicated Fan', '🌟', 'bronze', '20 plays across all games combined', 15, 44),
  ('dedicated_silver', 'Across all games', 'Dedicated Fan', '🌟', 'silver', '100 plays across all games combined', 60, 45),
  ('dedicated_gold', 'Across all games', 'Dedicated Fan', '🌟', 'gold', '500 plays across all games combined', 250, 45),

  -- Predictor: an easy first prediction, since everything else here
  -- needed real accumulated history to unlock anything at all.
  ('predictor_first_bronze', 'Predictor', 'First Prediction', '📝', 'bronze', 'Made your first prediction', 10, 49),

  -- Leagues: joining or starting your first league, both genuinely
  -- easy day-one wins that were missing before.
  ('leagues_first_bronze', 'Leagues', 'First League', '🚪', 'bronze', 'Joined your first league', 10, 69),
  ('leagues_founder_bronze', 'Leagues', 'Founder', '🛠️', 'bronze', 'Created a league', 15, 75)
on conflict (key) do nothing;

-- Replaces calculate_achievements() in full, same function, same
-- signature, extended with checks for everything added above.
create or replace function calculate_achievements(uid uuid) returns void as $$
declare
  stats jsonb;
  m1_played int; m1_wins int; m1_streak int;
  m2_played int; m2_wins int; m2_streak int;
  m3_played int; m3_wins int; m3_streak int;
  m4_played int; m4_wins int; m4_streak int;
  total_played int;
  games_with_badge int;
  predictor_predictions int;
  predictor_streak int;
  predictor_season_pts int;
  predictor_wildcard_types int;
  predictor_scorer_hits int;
  league_count int;
  league_founded int;
  best_league_rank int;
begin
  select s.stats into stats from user_stats s where s.user_id = uid;
  if stats is null then stats := '{}'::jsonb; end if;

  m1_played := coalesce((stats->'m1'->>'played')::int, 0);
  m1_wins := coalesce((stats->'m1'->>'wins')::int, 0);
  m1_streak := coalesce((stats->'m1'->>'maxStreak')::int, 0);
  m2_played := coalesce((stats->'m2'->>'played')::int, 0);
  m2_wins := coalesce((stats->'m2'->>'wins')::int, 0);
  m2_streak := coalesce((stats->'m2'->>'maxStreak')::int, 0);
  m3_played := coalesce((stats->'m3'->>'played')::int, 0);
  m3_wins := coalesce((stats->'m3'->>'wins')::int, 0);
  m3_streak := coalesce((stats->'m3'->>'maxStreak')::int, 0);
  m4_played := coalesce((stats->'m4'->>'played')::int, 0);
  m4_wins := coalesce((stats->'m4'->>'wins')::int, 0);
  m4_streak := coalesce((stats->'m4'->>'maxStreak')::int, 0);
  total_played := m1_played + m2_played + m3_played + m4_played;

  -- TIGERDLE
  if m1_wins >= 1 then insert into user_achievements values (uid, 'tigerdle_first_bronze', now()) on conflict do nothing; end if;
  if m1_streak >= 3 then insert into user_achievements values (uid, 'tigerdle_streak_bronze', now()) on conflict do nothing; end if;
  if m1_streak >= 7 then insert into user_achievements values (uid, 'tigerdle_streak_silver', now()) on conflict do nothing; end if;
  if m1_streak >= 30 then insert into user_achievements values (uid, 'tigerdle_streak_gold', now()) on conflict do nothing; end if;
  if m1_streak >= 100 then insert into user_achievements values (uid, 'tigerdle_streak_platinum', now()) on conflict do nothing; end if;
  if m1_wins >= 25 then insert into user_achievements values (uid, 'tigerdle_wins_bronze', now()) on conflict do nothing; end if;
  if m1_wins >= 100 then insert into user_achievements values (uid, 'tigerdle_wins_silver', now()) on conflict do nothing; end if;
  if m1_wins >= 365 then insert into user_achievements values (uid, 'tigerdle_wins_gold', now()) on conflict do nothing; end if;
  if m1_played >= 10 then insert into user_achievements values (uid, 'tigerdle_played_bronze', now()) on conflict do nothing; end if;
  if m1_played >= 50 then insert into user_achievements values (uid, 'tigerdle_played_silver', now()) on conflict do nothing; end if;
  if m1_played >= 150 then insert into user_achievements values (uid, 'tigerdle_played_gold', now()) on conflict do nothing; end if;

  -- Guess the Tiger
  if m2_wins >= 1 then insert into user_achievements values (uid, 'tiger_first_bronze', now()) on conflict do nothing; end if;
  if m2_wins >= 10 then insert into user_achievements values (uid, 'tiger_wins_bronze', now()) on conflict do nothing; end if;
  if m2_wins >= 50 then insert into user_achievements values (uid, 'tiger_wins_silver', now()) on conflict do nothing; end if;
  if m2_wins >= 200 then insert into user_achievements values (uid, 'tiger_wins_gold', now()) on conflict do nothing; end if;
  if m2_streak >= 3 then insert into user_achievements values (uid, 'tiger_streak_bronze', now()) on conflict do nothing; end if;
  if m2_streak >= 7 then insert into user_achievements values (uid, 'tiger_streak_silver', now()) on conflict do nothing; end if;
  if m2_streak >= 30 then insert into user_achievements values (uid, 'tiger_streak_gold', now()) on conflict do nothing; end if;
  if m2_played >= 10 then insert into user_achievements values (uid, 'tiger_played_bronze', now()) on conflict do nothing; end if;
  if m2_played >= 50 then insert into user_achievements values (uid, 'tiger_played_silver', now()) on conflict do nothing; end if;
  if m2_played >= 150 then insert into user_achievements values (uid, 'tiger_played_gold', now()) on conflict do nothing; end if;

  -- Mystery Tiger
  if m3_wins >= 1 then insert into user_achievements values (uid, 'mystery_first_bronze', now()) on conflict do nothing; end if;
  if m3_played >= 30 then insert into user_achievements values (uid, 'mystery_played_bronze', now()) on conflict do nothing; end if;
  if m3_played >= 100 then insert into user_achievements values (uid, 'mystery_played_silver', now()) on conflict do nothing; end if;
  if m3_played >= 365 then insert into user_achievements values (uid, 'mystery_played_gold', now()) on conflict do nothing; end if;
  if m3_streak >= 3 then insert into user_achievements values (uid, 'mystery_streak_bronze', now()) on conflict do nothing; end if;
  if m3_streak >= 7 then insert into user_achievements values (uid, 'mystery_streak_silver', now()) on conflict do nothing; end if;
  if m3_streak >= 30 then insert into user_achievements values (uid, 'mystery_streak_gold', now()) on conflict do nothing; end if;
  if m3_wins >= 10 then insert into user_achievements values (uid, 'mystery_wins_bronze', now()) on conflict do nothing; end if;
  if m3_wins >= 50 then insert into user_achievements values (uid, 'mystery_wins_silver', now()) on conflict do nothing; end if;
  if m3_wins >= 200 then insert into user_achievements values (uid, 'mystery_wins_gold', now()) on conflict do nothing; end if;

  -- Guess the Opponent
  if m4_wins >= 1 then insert into user_achievements values (uid, 'opponent_first_bronze', now()) on conflict do nothing; end if;
  if m4_played >= 20 then insert into user_achievements values (uid, 'opponent_played_bronze', now()) on conflict do nothing; end if;
  if m4_played >= 75 then insert into user_achievements values (uid, 'opponent_played_silver', now()) on conflict do nothing; end if;
  if m4_played >= 250 then insert into user_achievements values (uid, 'opponent_played_gold', now()) on conflict do nothing; end if;
  if m4_streak >= 3 then insert into user_achievements values (uid, 'opponent_streak_bronze', now()) on conflict do nothing; end if;
  if m4_streak >= 7 then insert into user_achievements values (uid, 'opponent_streak_silver', now()) on conflict do nothing; end if;
  if m4_streak >= 30 then insert into user_achievements values (uid, 'opponent_streak_gold', now()) on conflict do nothing; end if;
  if m4_wins >= 10 then insert into user_achievements values (uid, 'opponent_wins_bronze', now()) on conflict do nothing; end if;
  if m4_wins >= 50 then insert into user_achievements values (uid, 'opponent_wins_silver', now()) on conflict do nothing; end if;
  if m4_wins >= 200 then insert into user_achievements values (uid, 'opponent_wins_gold', now()) on conflict do nothing; end if;

  -- Full House: played every game at least once
  if m1_played > 0 and m2_played > 0 and m3_played > 0 and m4_played > 0 then
    insert into user_achievements values (uid, 'full_house_bronze', now()) on conflict do nothing;
  end if;

  if total_played >= 20 then insert into user_achievements values (uid, 'dedicated_bronze', now()) on conflict do nothing; end if;
  if total_played >= 100 then insert into user_achievements values (uid, 'dedicated_silver', now()) on conflict do nothing; end if;
  if total_played >= 500 then insert into user_achievements values (uid, 'dedicated_gold', now()) on conflict do nothing; end if;

  select count(distinct category) into games_with_badge
  from user_achievements ua join achievement_definitions ad on ad.key = ua.achievement_key
  where ua.user_id = uid and ad.category in ('TIGERDLE','Guess the Tiger','Mystery Tiger','Guess the Opponent');
  if games_with_badge >= 2 then insert into user_achievements values (uid, 'well_rounded_bronze', now()) on conflict do nothing; end if;
  if games_with_badge >= 3 then insert into user_achievements values (uid, 'well_rounded_silver', now()) on conflict do nothing; end if;
  if games_with_badge >= 4 then insert into user_achievements values (uid, 'well_rounded_gold', now()) on conflict do nothing; end if;

  -- Predictor
  select count(*) into predictor_predictions from prediction_scores where user_id = uid;
  if predictor_predictions >= 1 then insert into user_achievements values (uid, 'predictor_first_bronze', now()) on conflict do nothing; end if;

  select coalesce(max(streak_len), 0) into predictor_streak from (
    select count(*) as streak_len from (
      select calculated_at,
        sum(case when score_points = 0 then 1 else 0 end) over (order by calculated_at desc) as break_group
      from prediction_scores where user_id = uid
    ) t where break_group = 0
  ) s;
  if predictor_streak >= 3 then insert into user_achievements values (uid, 'predictor_streak_bronze', now()) on conflict do nothing; end if;
  if predictor_streak >= 7 then insert into user_achievements values (uid, 'predictor_streak_silver', now()) on conflict do nothing; end if;
  if predictor_streak >= 15 then insert into user_achievements values (uid, 'predictor_streak_gold', now()) on conflict do nothing; end if;
  if predictor_streak >= 25 then insert into user_achievements values (uid, 'predictor_streak_platinum', now()) on conflict do nothing; end if;

  select coalesce(sum(total_points), 0) into predictor_season_pts
  from prediction_scores ps join fixtures f on f.id = ps.fixture_id
  where ps.user_id = uid and football_season(f.match_date) = football_season(current_date);
  if predictor_season_pts >= 50 then insert into user_achievements values (uid, 'predictor_points_bronze', now()) on conflict do nothing; end if;
  if predictor_season_pts >= 150 then insert into user_achievements values (uid, 'predictor_points_silver', now()) on conflict do nothing; end if;
  if predictor_season_pts >= 300 then insert into user_achievements values (uid, 'predictor_points_gold', now()) on conflict do nothing; end if;

  select count(distinct wildcard_applied) into predictor_wildcard_types
  from prediction_scores where user_id = uid and wildcard_applied is not null and total_points > 0;
  if predictor_wildcard_types >= 1 then insert into user_achievements values (uid, 'predictor_wildcard_bronze', now()) on conflict do nothing; end if;
  if predictor_wildcard_types >= 2 then insert into user_achievements values (uid, 'predictor_wildcard_silver', now()) on conflict do nothing; end if;
  if predictor_wildcard_types >= 4 then insert into user_achievements values (uid, 'predictor_wildcard_gold', now()) on conflict do nothing; end if;

  select count(*) into predictor_scorer_hits from prediction_scores
  where user_id = uid and (scorer_points > 0 or first_scorer_points > 0);
  if predictor_scorer_hits >= 5 then insert into user_achievements values (uid, 'predictor_scorer_bronze', now()) on conflict do nothing; end if;
  if predictor_scorer_hits >= 15 then insert into user_achievements values (uid, 'predictor_scorer_silver', now()) on conflict do nothing; end if;
  if predictor_scorer_hits >= 40 then insert into user_achievements values (uid, 'predictor_scorer_gold', now()) on conflict do nothing; end if;

  -- Leagues
  select count(*) into league_count from league_members where user_id = uid;
  if league_count >= 1 then insert into user_achievements values (uid, 'leagues_first_bronze', now()) on conflict do nothing; end if;
  if league_count >= 2 then insert into user_achievements values (uid, 'leagues_joined_bronze', now()) on conflict do nothing; end if;
  if league_count >= 5 then insert into user_achievements values (uid, 'leagues_joined_silver', now()) on conflict do nothing; end if;
  if league_count >= 10 then insert into user_achievements values (uid, 'leagues_joined_gold', now()) on conflict do nothing; end if;

  select count(*) into league_founded from leagues where created_by = uid;
  if league_founded >= 1 then insert into user_achievements values (uid, 'leagues_founder_bronze', now()) on conflict do nothing; end if;

  select min(rank) into best_league_rank from (
    select user_id, rank() over (partition by league_id order by total_points desc) as rank
    from league_leaderboard
  ) r where r.user_id = uid;
  if best_league_rank <= 3 then insert into user_achievements values (uid, 'leagues_top3_silver', now()) on conflict do nothing; end if;
  if best_league_rank = 1 then insert into user_achievements values (uid, 'leagues_won_gold', now()) on conflict do nothing; end if;
end;
$$ language plpgsql security definer;

-- Lets the site tell someone about an achievement once, then never
-- again. chrome.js checks for unseen ones on every page load while
-- signed in and marks them seen right after showing the toast.
alter table user_achievements add column if not exists seen boolean not null default false;
