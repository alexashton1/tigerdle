-- Run this once in the Supabase SQL editor. Achievement definitions,
-- what's actually been earned, and the optional (private by default)
-- badge someone can choose to show next to their name elsewhere on
-- the site.

-- calculate_achievements() below needs this, defined defensively here
-- too (identical to the copy in migrate_add_wildcards.sql) so this
-- migration doesn't silently depend on that one having been run first.
-- Harmless to redefine even if it already exists, same definition.
create or replace function football_season(d date) returns text as $$
  select case when extract(month from d) >= 7
    then extract(year from d)::text || '-' || right((extract(year from d)::int + 1)::text, 2)
    else (extract(year from d)::int - 1)::text || '-' || right(extract(year from d)::text, 2)
  end;
$$ language sql immutable;

create table if not exists achievement_definitions (
  key text primary key,
  category text not null,
  name text not null,
  icon text not null,
  tier text not null check (tier in ('bronze','silver','gold','platinum')),
  description text not null,
  points int not null,
  sort_order int not null default 0
);

alter table achievement_definitions enable row level security;
drop policy if exists "public read achievement definitions" on achievement_definitions;
create policy "public read achievement definitions" on achievement_definitions
  for select using (true);

create table if not exists user_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  achievement_key text not null references achievement_definitions(key) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, achievement_key)
);

alter table user_achievements enable row level security;
drop policy if exists "public read user achievements" on user_achievements;
create policy "public read user achievements" on user_achievements
  for select using (true);
-- No public INSERT policy, achievements are only ever earned via
-- calculate_achievements(), run as security definer below, never
-- inserted directly by a client. An UPDATE policy is needed, though,
-- the "seen" flag (added further down) is toggled from the browser
-- after a notification is shown, and without this, that update is
-- silently blocked and the same achievement re-announces forever.
drop policy if exists "users can mark own achievements seen" on user_achievements;
create policy "users can mark own achievements seen" on user_achievements
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- What someone's chosen to show next to their name elsewhere on the
-- site. 'status' shows their overall tier, an achievement key shows
-- that specific badge, and null (the default) means nothing shows at
-- all. Lives on profiles since that's already the public-safe,
-- narrow-columns table other pages already read display names from.
alter table profiles add column if not exists equipped_badge text;

-- Seed set: everything here is checkable against data that already
-- exists today. More will be added over time as more detailed
-- tracking gets built for each game.
insert into achievement_definitions (key, category, name, icon, tier, description, points, sort_order) values
  ('tigerdle_streak_bronze', 'TIGERDLE', 'Word Streak', '🔥', 'bronze', '3-day streak', 15, 1),
  ('tigerdle_streak_silver', 'TIGERDLE', 'Word Streak', '🔥', 'silver', '7-day streak', 40, 2),
  ('tigerdle_streak_gold', 'TIGERDLE', 'Word Streak', '🔥', 'gold', '30-day streak', 120, 3),
  ('tigerdle_streak_platinum', 'TIGERDLE', 'Word Streak', '🔥', 'platinum', '100-day streak', 400, 4),
  ('tigerdle_wins_bronze', 'TIGERDLE', 'Century Club', '💯', 'bronze', '25 total wins', 20, 5),
  ('tigerdle_wins_silver', 'TIGERDLE', 'Century Club', '💯', 'silver', '100 total wins', 80, 6),
  ('tigerdle_wins_gold', 'TIGERDLE', 'Century Club', '💯', 'gold', '365 total wins', 300, 7),

  ('tiger_wins_bronze', 'Guess the Tiger', 'Tiger Tamer', '🐯', 'bronze', '10 wins', 10, 10),
  ('tiger_wins_silver', 'Guess the Tiger', 'Tiger Tamer', '🐯', 'silver', '50 wins', 40, 11),
  ('tiger_wins_gold', 'Guess the Tiger', 'Tiger Tamer', '🐯', 'gold', '200 wins', 150, 12),

  ('mystery_played_bronze', 'Mystery Tiger', 'Ever Curious', '📅', 'bronze', '30 days played', 15, 20),
  ('mystery_played_silver', 'Mystery Tiger', 'Ever Curious', '📅', 'silver', '100 days played', 60, 21),
  ('mystery_played_gold', 'Mystery Tiger', 'Ever Curious', '📅', 'gold', '365 days played', 250, 22),

  ('opponent_played_bronze', 'Guess the Opponent', 'Season Regular', '🗓️', 'bronze', '20 plays', 10, 30),
  ('opponent_played_silver', 'Guess the Opponent', 'Season Regular', '🗓️', 'silver', '75 plays', 45, 31),
  ('opponent_played_gold', 'Guess the Opponent', 'Season Regular', '🗓️', 'gold', '250 plays', 180, 32),

  ('full_house_bronze', 'Across all games', 'Full House', '🎮', 'bronze', 'Played all 4 games at least once', 20, 40),
  ('well_rounded_bronze', 'Across all games', 'Well Rounded', '🧩', 'bronze', 'Earned a badge in 2 different games', 15, 41),
  ('well_rounded_silver', 'Across all games', 'Well Rounded', '🧩', 'silver', 'Earned a badge in 3 different games', 45, 42),
  ('well_rounded_gold', 'Across all games', 'Well Rounded', '🧩', 'gold', 'Earned a badge in every game', 150, 43),

  ('predictor_streak_bronze', 'Predictor', 'Prediction Streak', '⚡', 'bronze', '3 correct results running', 20, 50),
  ('predictor_streak_silver', 'Predictor', 'Prediction Streak', '⚡', 'silver', '7 correct results running', 70, 51),
  ('predictor_streak_gold', 'Predictor', 'Prediction Streak', '⚡', 'gold', '15 correct results running', 250, 52),
  ('predictor_streak_platinum', 'Predictor', 'Prediction Streak', '⚡', 'platinum', '25 correct results running', 700, 53),
  ('predictor_points_bronze', 'Predictor', 'Season Points', '🏅', 'bronze', '50pts in a season', 15, 54),
  ('predictor_points_silver', 'Predictor', 'Season Points', '🏅', 'silver', '150pts in a season', 50, 55),
  ('predictor_points_gold', 'Predictor', 'Season Points', '🏅', 'gold', '300pts in a season', 150, 56),
  ('predictor_wildcard_bronze', 'Predictor', 'Wildcard Master', '🃏', 'bronze', 'Cashed in 1 wildcard', 20, 57),
  ('predictor_wildcard_silver', 'Predictor', 'Wildcard Master', '🃏', 'silver', 'Cashed in 2 different types', 60, 58),
  ('predictor_wildcard_gold', 'Predictor', 'Wildcard Master', '🃏', 'gold', 'Cashed in all 4 types', 220, 59),
  ('predictor_scorer_bronze', 'Predictor', 'Scout''s Eye', '⚽', 'bronze', '5 correct scorer picks', 15, 60),
  ('predictor_scorer_silver', 'Predictor', 'Scout''s Eye', '⚽', 'silver', '15 correct scorer picks', 50, 61),
  ('predictor_scorer_gold', 'Predictor', 'Scout''s Eye', '⚽', 'gold', '40 correct scorer picks', 180, 62),

  ('leagues_joined_bronze', 'Leagues', 'Social Butterfly', '🤝', 'bronze', 'In 2 leagues at once', 10, 70),
  ('leagues_joined_silver', 'Leagues', 'Social Butterfly', '🤝', 'silver', 'In 5 leagues at once', 35, 71),
  ('leagues_joined_gold', 'Leagues', 'Social Butterfly', '🤝', 'gold', 'In 10 leagues at once', 100, 72),
  ('leagues_top3_silver', 'Leagues', 'League Success', '🏆', 'silver', 'Top 3 in any league', 60, 73),
  ('leagues_won_gold', 'Leagues', 'League Success', '🏆', 'gold', 'Currently rank 1 in any league', 220, 74)
on conflict (key) do nothing;

-- Works out which achievements a user has actually earned, checked
-- against real data, and records any new ones. Safe to call as often
-- as needed. Already-earned achievements are never re-awarded or
-- removed, so nobody loses a badge because a stat dipped later.
create or replace function calculate_achievements(uid uuid) returns void as $$
declare
  stats jsonb;
  m1_played int; m1_wins int; m1_streak int;
  m2_wins int;
  m3_played int;
  m4_played int;
  games_with_badge int;
  predictor_streak int;
  predictor_season_pts int;
  predictor_wildcard_types int;
  predictor_scorer_hits int;
  league_count int;
  best_league_rank int;
begin
  select s.stats into stats from user_stats s where s.user_id = uid;
  if stats is null then stats := '{}'::jsonb; end if;

  m1_played := coalesce((stats->'m1'->>'played')::int, 0);
  m1_wins := coalesce((stats->'m1'->>'wins')::int, 0);
  m1_streak := coalesce((stats->'m1'->>'maxStreak')::int, 0);
  m2_wins := coalesce((stats->'m2'->>'wins')::int, 0);
  m3_played := coalesce((stats->'m3'->>'played')::int, 0);
  m4_played := coalesce((stats->'m4'->>'played')::int, 0);

  -- TIGERDLE
  if m1_streak >= 3 then insert into user_achievements values (uid, 'tigerdle_streak_bronze', now()) on conflict do nothing; end if;
  if m1_streak >= 7 then insert into user_achievements values (uid, 'tigerdle_streak_silver', now()) on conflict do nothing; end if;
  if m1_streak >= 30 then insert into user_achievements values (uid, 'tigerdle_streak_gold', now()) on conflict do nothing; end if;
  if m1_streak >= 100 then insert into user_achievements values (uid, 'tigerdle_streak_platinum', now()) on conflict do nothing; end if;
  if m1_wins >= 25 then insert into user_achievements values (uid, 'tigerdle_wins_bronze', now()) on conflict do nothing; end if;
  if m1_wins >= 100 then insert into user_achievements values (uid, 'tigerdle_wins_silver', now()) on conflict do nothing; end if;
  if m1_wins >= 365 then insert into user_achievements values (uid, 'tigerdle_wins_gold', now()) on conflict do nothing; end if;

  -- Guess the Tiger
  if m2_wins >= 10 then insert into user_achievements values (uid, 'tiger_wins_bronze', now()) on conflict do nothing; end if;
  if m2_wins >= 50 then insert into user_achievements values (uid, 'tiger_wins_silver', now()) on conflict do nothing; end if;
  if m2_wins >= 200 then insert into user_achievements values (uid, 'tiger_wins_gold', now()) on conflict do nothing; end if;

  -- Mystery Tiger
  if m3_played >= 30 then insert into user_achievements values (uid, 'mystery_played_bronze', now()) on conflict do nothing; end if;
  if m3_played >= 100 then insert into user_achievements values (uid, 'mystery_played_silver', now()) on conflict do nothing; end if;
  if m3_played >= 365 then insert into user_achievements values (uid, 'mystery_played_gold', now()) on conflict do nothing; end if;

  -- Guess the Opponent
  if m4_played >= 20 then insert into user_achievements values (uid, 'opponent_played_bronze', now()) on conflict do nothing; end if;
  if m4_played >= 75 then insert into user_achievements values (uid, 'opponent_played_silver', now()) on conflict do nothing; end if;
  if m4_played >= 250 then insert into user_achievements values (uid, 'opponent_played_gold', now()) on conflict do nothing; end if;

  -- Full House: played every game at least once
  if m1_played > 0 and m2_wins >= 0 and (stats->'m2'->>'played')::int > 0
     and m3_played > 0 and m4_played > 0 then
    insert into user_achievements values (uid, 'full_house_bronze', now()) on conflict do nothing;
  end if;

  -- Well Rounded: counted after the game-specific ones above, so
  -- this always reflects what was just calculated this run too.
  select count(distinct category) into games_with_badge
  from user_achievements ua join achievement_definitions ad on ad.key = ua.achievement_key
  where ua.user_id = uid and ad.category in ('TIGERDLE','Guess the Tiger','Mystery Tiger','Guess the Opponent');
  if games_with_badge >= 2 then insert into user_achievements values (uid, 'well_rounded_bronze', now()) on conflict do nothing; end if;
  if games_with_badge >= 3 then insert into user_achievements values (uid, 'well_rounded_silver', now()) on conflict do nothing; end if;
  if games_with_badge >= 4 then insert into user_achievements values (uid, 'well_rounded_gold', now()) on conflict do nothing; end if;

  -- Predictor: longest run of consecutive correct results, most
  -- recent scored fixtures first, broken the moment a fixture without
  -- at least a correct result is hit.
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
  if league_count >= 2 then insert into user_achievements values (uid, 'leagues_joined_bronze', now()) on conflict do nothing; end if;
  if league_count >= 5 then insert into user_achievements values (uid, 'leagues_joined_silver', now()) on conflict do nothing; end if;
  if league_count >= 10 then insert into user_achievements values (uid, 'leagues_joined_gold', now()) on conflict do nothing; end if;

  select min(rank) into best_league_rank from (
    select user_id, rank() over (partition by league_id order by total_points desc) as rank
    from league_leaderboard
  ) r where r.user_id = uid;
  if best_league_rank <= 3 then insert into user_achievements values (uid, 'leagues_top3_silver', now()) on conflict do nothing; end if;
  if best_league_rank = 1 then insert into user_achievements values (uid, 'leagues_won_gold', now()) on conflict do nothing; end if;
end;
$$ language plpgsql security definer;
