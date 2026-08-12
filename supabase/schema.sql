-- =========================================================
-- TIGERDLE: Supabase schema
-- Run this once in the Supabase SQL editor for a new project.
-- =========================================================

create extension if not exists pgcrypto;

-- ---------- players ----------
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  position text not null check (position in ('GK','DF','MF','FW')),
  nationality text not null default 'Unknown',
  era text not null default 'Current Squad',
  age int,
  birth_date date,
  appearances int,
  appearances_updated_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table players enable row level security;

drop policy if exists "public read active players" on players;
create policy "public read active players" on players
  for select using (true);

-- Left-to-right placement within a position line on any pitch view.
alter table players add column if not exists pitch_order int;
-- No insert/update/delete policies for anon/authenticated: all writes go
-- through the admin-action edge function using the service role key.

-- ---------- posts ----------
create table if not exists posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  slug text not null unique,
  excerpt text,
  body_md text not null default '',
  published boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now()
);

alter table posts enable row level security;

drop policy if exists "public read published posts" on posts;
create policy "public read published posts" on posts
  for select using (published = true);
-- Writes go through admin-action (service role) so drafts stay hidden
-- from anon reads while still being manageable from the admin panel
-- (the admin panel reads posts via the same anon key, so drafts would
-- normally be invisible to it too, the admin page instead relies on
-- the fact that only you know the passphrase to reach admin-action,
-- and can extend this policy to authenticated if you add real login later).

-- ---------- subscribers ----------
create table if not exists subscribers (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  subscribed boolean not null default true,
  unsubscribe_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table subscribers enable row level security;

drop policy if exists "public can subscribe" on subscribers;
create policy "public can subscribe" on subscribers
  for insert with check (true);
-- No select/update/delete for anon, reading the list, sending email,
-- and unsubscribing all happen through edge functions with the service
-- role key, so email addresses are never exposed to the browser.

-- ---------- user_stats (accounts, separate from the rest of the site,
-- which stays completely login-free) ----------
create table if not exists user_stats (
  user_id uuid primary key references auth.users(id) on delete cascade,
  stats jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table user_stats enable row level security;

drop policy if exists "users read own stats" on user_stats;
create policy "users read own stats" on user_stats
  for select using (auth.uid() = user_id);

drop policy if exists "users insert own stats" on user_stats;
create policy "users insert own stats" on user_stats
  for insert with check (auth.uid() = user_id);

drop policy if exists "users update own stats" on user_stats;
create policy "users update own stats" on user_stats
  for update using (auth.uid() = user_id);

-- ---------- fixtures ----------
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

-- ---------- matchdays (lineups, formations, ratings) ----------
create table if not exists matchdays (
  id uuid primary key default gen_random_uuid(),
  match_date date not null,
  opponent text not null,
  competition text,
  home_away text check (home_away in ('Home','Away')),
  hull_score int,
  opponent_score int,
  formation text not null,
  lineup jsonb not null default '[]'::jsonb,
  appearances_counted_for jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table matchdays enable row level security;

drop policy if exists "public read matchdays" on matchdays;
create policy "public read matchdays" on matchdays
  for select using (true);

create index if not exists matchdays_date_idx on matchdays(match_date desc);

-- ---------- goals ("Guess the Opponent" puzzles) ----------
create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  image_url text not null,
  opponent text not null,
  competition text,
  match_date date,
  puzzle_date date unique,
  created_at timestamptz not null default now()
);

alter table goals enable row level security;

drop policy if exists "public read goals" on goals;
create policy "public read goals" on goals
  for select using (true);

-- ---------- storage bucket for goal photos ----------
insert into storage.buckets (id, name, public)
values ('goal-images', 'goal-images', true)
on conflict (id) do nothing;

-- Public can read (bucket is public); only the service role (used inside
-- the admin-action edge function) can write, so uploads always go through
-- the passphrase check.
drop policy if exists "public read goal images" on storage.objects;
create policy "public read goal images" on storage.objects
  for select using (bucket_id = 'goal-images');

-- ---------- leagues ----------
create table if not exists leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text unique not null,
  is_public boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists league_members (
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);

alter table leagues enable row level security;
alter table league_members enable row level security;

-- A league is visible if it's public, or you're already a member, or
-- you created it. A private league you don't belong to is invisible,
-- you can't browse your way into it, only join by knowing its code
-- (via the function below, which looks it up without needing this
-- policy to allow it).
drop policy if exists "leagues visible if public or member" on leagues;
create policy "leagues visible if public or member" on leagues
  for select using (
    is_public = true
    or created_by = auth.uid()
    or id in (select league_id from league_members where user_id = auth.uid())
  );

drop policy if exists "users create leagues" on leagues;
create policy "users create leagues" on leagues
  for insert with check (auth.uid() = created_by);

-- Members of a league can see who else is in it.
create or replace function is_league_member(check_league_id uuid, check_user_id uuid)
returns boolean as $$
  select exists(
    select 1 from league_members
    where league_id = check_league_id and user_id = check_user_id
  );
$$ language sql stable security definer;

drop policy if exists "members see other members" on league_members;
create policy "members see other members" on league_members
  for select using (
    is_league_member(league_members.league_id, auth.uid())
  );

-- Direct self-join only works for public leagues. Joining a private
-- one requires the code, enforced by the function below instead.
drop policy if exists "users join public leagues directly" on league_members;
create policy "users join public leagues directly" on league_members
  for insert with check (
    auth.uid() = user_id
    and exists (select 1 from leagues l where l.id = league_members.league_id and l.is_public = true)
  );

-- Creating a league: picks a name, generates a unique code, creates the
-- league, and joins the creator as its first member, all in one call.
create or replace function create_league(league_name text, make_public boolean default false)
returns table(result_league_id uuid, result_league_code text) as $$
declare
  v_code text;
  v_league_id uuid;
begin
  loop
    v_code := upper(substr(md5(random()::text), 1, 6));
    exit when not exists (select 1 from leagues where code = v_code);
  end loop;
  insert into leagues (name, code, is_public, created_by)
    values (league_name, v_code, make_public, auth.uid())
    returning id into v_league_id;
  insert into league_members (league_id, user_id) values (v_league_id, auth.uid());
  return query select v_league_id, v_code;
end;
$$ language plpgsql security definer;

-- Joining a private league by code: looks the league up by its exact
-- code (bypassing the "can't browse private leagues" rule, safely,
-- since you have to already know the code) and adds you as a member.
-- Wrong code just raises an error, no information leaked either way.
create or replace function join_league_by_code(join_code text)
returns table(result_league_id uuid, result_league_name text) as $$
declare
  target leagues%rowtype;
begin
  select * into target from leagues where code = upper(join_code);
  if not found then
    raise exception 'That code doesn''t match a league. Double-check it and try again.';
  end if;
  insert into league_members (league_id, user_id) values (target.id, auth.uid())
    on conflict (league_id, user_id) do nothing;
  return query select target.id, target.name;
end;
$$ language plpgsql security definer;

-- Seeds one public league so there's always at least one to see,
-- "Overall", open to anyone, no code needed.
insert into leagues (name, code, is_public, created_by)
select 'Overall', 'OVERALL', true, null
where not exists (select 1 from leagues where code = 'OVERALL');

-- ---------- scoring system ----------
-- 1. Lock predictions 75 minutes before kickoff, not at kickoff,
--    matching when official team sheets actually come out.
-- =========================================================
create or replace function fixture_not_started(fid uuid) returns boolean as $$
  select coalesce(
    (select (match_date + coalesce(kickoff_time, '00:00')::time - interval '75 minutes') > now()
     from fixtures where id = fid),
    false
  );
$$ language sql stable;
-- (Same BST/UTC caveat as before, team sheets close 75 minutes before
-- your entered kickoff time, compared against the server's UTC clock.)

-- =========================================================
-- 2. Link a matchday to its fixture, and record who scored and in
--    what order, needed to know both "any scorer" and "first scorer".
-- =========================================================
alter table matchdays add column if not exists fixture_id uuid references fixtures(id) on delete set null;
alter table matchdays add column if not exists goalscorers jsonb not null default '[]'::jsonb;
-- goalscorers shape: [{player_id, first_name, last_name}, ...]. Index 0
-- is the first goal of the match, in order after that.

create index if not exists matchdays_fixture_idx on matchdays(fixture_id);

-- =========================================================
-- 3. Where computed scores live: one row per user per fixture,
--    with the full breakdown kept so it can be shown, not just the total.
-- =========================================================
create table if not exists prediction_scores (
  id uuid primary key default gen_random_uuid(),
  prediction_id uuid not null references predictions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  fixture_id uuid not null references fixtures(id) on delete cascade,
  position_points int not null default 0,
  score_points int not null default 0,
  scorer_points int not null default 0,
  first_scorer_points int not null default 0,
  total_points int not null default 0,
  breakdown jsonb not null default '{}'::jsonb,
  calculated_at timestamptz not null default now(),
  unique(user_id, fixture_id)
);

-- In case prediction_scores already existed from an earlier run of this
-- migration, before the breakdown column was added.
alter table prediction_scores add column if not exists breakdown jsonb not null default '{}'::jsonb;

alter table prediction_scores enable row level security;

-- Own scores are always visible. League-mates' scores are visible too,
-- once calculated, that's the "view each other's results" part,
-- but only within a shared league, never site-wide.
drop policy if exists "users see own scores" on prediction_scores;
create policy "users see own scores" on prediction_scores
  for select using (auth.uid() = user_id);

drop policy if exists "league mates see each others scores" on prediction_scores;
create policy "league mates see each others scores" on prediction_scores
  for select using (
    exists (
      select 1 from league_members lm1
      join league_members lm2 on lm1.league_id = lm2.league_id
      where lm1.user_id = auth.uid() and lm2.user_id = prediction_scores.user_id
    )
  );

-- Once a fixture's scored, league-mates can also see the actual
-- prediction behind that score (not just the number), again, only
-- after scoring (so nobody can copy a pick pre-match), and only within
-- a shared league (never the whole site).
drop policy if exists "league mates see each others scored predictions" on predictions;
create policy "league mates see each others scored predictions" on predictions
  for select using (
    exists (select 1 from prediction_scores ps where ps.prediction_id = predictions.id)
    and exists (
      select 1 from league_members lm1
      join league_members lm2 on lm1.league_id = lm2.league_id
      where lm1.user_id = auth.uid() and lm2.user_id = predictions.user_id
    )
  );

-- =========================================================
-- 4. The actual points engine. Triggered manually from admin once
--    you've entered a matchday's real lineup, score, and goalscorers,
--    deliberately not automatic, so nothing gets scored off an
--    incomplete result.
-- =========================================================
-- Admin's matchday builder still records specific slots (RB, CB, ST,
-- etc.) since that's genuinely useful detail for the team-news pitch
-- view. Predictions only ever capture broad position (GK/DF/MF/FW),
-- since that's what the picker asks for. This bridges the two for
-- scoring, so "predicted a defender, actual lineup had a CB there"
-- counts as a match.
create or replace function slot_to_broad_position(slot text) returns text as $$
  select case slot
    when 'GK' then 'GK'
    when 'RB' then 'DF' when 'CB' then 'DF' when 'LB' then 'DF'
    when 'RWB' then 'DF' when 'LWB' then 'DF'
    when 'CDM' then 'MF' when 'CM' then 'MF' when 'CAM' then 'MF'
    when 'RM' then 'MF' when 'LM' then 'MF'
    when 'RW' then 'FW' when 'LW' then 'FW' when 'ST' then 'FW'
    else null
  end;
$$ language sql immutable;

alter table predictions add column if not exists wildcard text
  check (wildcard in ('double', 'clean_sheet', 'hat_trick_hero', 'reverse_score'));

alter table prediction_scores add column if not exists clean_sheet_points int not null default 0;
alter table prediction_scores add column if not exists wildcard_applied text;

-- Which football season a date falls in, as a label like '2026-27'.
-- Seasons run August to May, so July onward counts as the start of a
-- new season, matches how the Premier League itself labels seasons.
-- Used to enforce "once per season" per wildcard.
create or replace function football_season(d date) returns text as $$
  select case when extract(month from d) >= 7
    then extract(year from d)::text || '-' || right((extract(year from d)::int + 1)::text, 2)
    else (extract(year from d)::int - 1)::text || '-' || right(extract(year from d)::text, 2)
  end;
$$ language sql immutable;

-- Rewritten scoring function, same core logic as before, with each
-- wildcard's effect layered on afterward, only when that prediction
-- actually used it.
create or replace function calculate_fixture_scores(fid uuid)
returns table(scored_count int) as $$
declare
  md matchdays%rowtype;
  pred predictions%rowtype;
  pos_pts int;
  score_pts int;
  scorer_pts int;
  first_scorer_pts int;
  clean_sheet_pts int;
  lineup_item jsonb;
  first_scorer_id text;
  scorer_position text;
  scorer_item jsonb;
  count_scored int := 0;
  correct_positions jsonb;
  score_result text;
  predicted_scorer_detail jsonb;
  first_scorer_detail jsonb;
  breakdown_json jsonb;
  gk_df_count int;
  total_pts int;
begin
  select * into md from matchdays where fixture_id = fid order by created_at desc limit 1;
  if not found then
    raise exception 'No matchday result found for this fixture yet, enter one in admin first.';
  end if;

  first_scorer_id := md.goalscorers->0->>'player_id';

  for pred in select * from predictions where fixture_id = fid loop
    pos_pts := 0;
    correct_positions := '[]'::jsonb;
    gk_df_count := 0;

    for lineup_item in select jsonb_array_elements(pred.lineup) loop
      if lineup_item->>'slot' in ('GK','DF') then
        gk_df_count := gk_df_count + 1;
      end if;
      if exists (
        select 1 from jsonb_array_elements(md.lineup) a_item
        where a_item->>'player_id' = lineup_item->>'player_id'
          and a_item->>'is_sub' = 'false'
          and slot_to_broad_position(a_item->>'slot') = lineup_item->>'slot'
      ) then
        pos_pts := pos_pts + 2;
        correct_positions := correct_positions || jsonb_build_object(
          'player_id', lineup_item->>'player_id',
          'first_name', lineup_item->>'first_name',
          'last_name', lineup_item->>'last_name',
          'slot', lineup_item->>'slot'
        );
      end if;
    end loop;

    -- Score / result points. Reverse Score also counts a mirrored
    -- exact match (predicted 1-0, actual finished 0-1) as a full hit.
    score_pts := 0;
    score_result := 'none';
    if pred.hull_score is not null and pred.opponent_score is not null
       and md.hull_score is not null and md.opponent_score is not null then
      if pred.hull_score = md.hull_score and pred.opponent_score = md.opponent_score then
        score_pts := 10; score_result := 'exact';
      elsif pred.wildcard = 'reverse_score' and pred.hull_score = md.opponent_score and pred.opponent_score = md.hull_score then
        score_pts := 10; score_result := 'exact_reversed';
      elsif sign(pred.hull_score - pred.opponent_score) = sign(md.hull_score - md.opponent_score) then
        score_pts := 5; score_result := 'result';
      end if;
    end if;

    -- Goalscorer points. Hat-trick Hero triples both categories.
    scorer_pts := 0;
    first_scorer_pts := 0;
    predicted_scorer_detail := null;
    first_scorer_detail := null;

    for scorer_item in select jsonb_array_elements(pred.scorers) loop
      select p.position into scorer_position from players p where p.id = (scorer_item->>'player_id')::uuid;

      if scorer_item->>'type' = 'predicted' then
        if exists (select 1 from jsonb_array_elements(md.goalscorers) g where g->>'player_id' = scorer_item->>'player_id') then
          scorer_pts := scorer_pts + case scorer_position
            when 'GK' then 10 when 'DF' then 10 when 'MF' then 7 when 'FW' then 5 else 0 end;
          predicted_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name',
            'hit', true, 'points', case scorer_position when 'GK' then 10 when 'DF' then 10 when 'MF' then 7 when 'FW' then 5 else 0 end
          );
        else
          predicted_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name', 'hit', false, 'points', 0
          );
        end if;
      end if;

      if scorer_item->>'type' = 'first' then
        if scorer_item->>'player_id' = first_scorer_id then
          first_scorer_pts := first_scorer_pts + case scorer_position
            when 'GK' then 20 when 'DF' then 20 when 'MF' then 15 when 'FW' then 10 else 0 end;
          first_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name',
            'hit', true, 'points', case scorer_position when 'GK' then 20 when 'DF' then 20 when 'MF' then 15 when 'FW' then 10 else 0 end
          );
        else
          first_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name', 'hit', false, 'points', 0
          );
        end if;
      end if;
    end loop;

    if pred.wildcard = 'hat_trick_hero' then
      scorer_pts := scorer_pts * 3;
      first_scorer_pts := first_scorer_pts * 3;
    end if;

    -- Clean Sheet Wildcard: 5 points per goalkeeper/defender predicted,
    -- only if Hull actually kept a clean sheet.
    clean_sheet_pts := 0;
    if pred.wildcard = 'clean_sheet' and md.opponent_score = 0 then
      clean_sheet_pts := gk_df_count * 5;
    end if;

    total_pts := pos_pts + score_pts + scorer_pts + first_scorer_pts + clean_sheet_pts;

    -- Double Points Wildcard: doubles everything this prediction earned.
    if pred.wildcard = 'double' then
      total_pts := total_pts * 2;
    end if;

    breakdown_json := jsonb_build_object(
      'correct_positions', correct_positions,
      'score_result', score_result,
      'predicted_hull_score', pred.hull_score,
      'predicted_opponent_score', pred.opponent_score,
      'actual_hull_score', md.hull_score,
      'actual_opponent_score', md.opponent_score,
      'predicted_scorer', predicted_scorer_detail,
      'first_scorer', first_scorer_detail,
      'wildcard', pred.wildcard,
      'clean_sheet_points', clean_sheet_pts
    );

    insert into prediction_scores (prediction_id, user_id, fixture_id, position_points, score_points, scorer_points, first_scorer_points, clean_sheet_points, wildcard_applied, total_points, breakdown, calculated_at)
    values (pred.id, pred.user_id, fid, pos_pts, score_pts, scorer_pts, first_scorer_pts, clean_sheet_pts, pred.wildcard, total_pts, breakdown_json, now())
    on conflict (user_id, fixture_id) do update set
      position_points = excluded.position_points,
      score_points = excluded.score_points,
      scorer_points = excluded.scorer_points,
      first_scorer_points = excluded.first_scorer_points,
      clean_sheet_points = excluded.clean_sheet_points,
      wildcard_applied = excluded.wildcard_applied,
      total_points = excluded.total_points,
      breakdown = excluded.breakdown,
      calculated_at = now();

    count_scored := count_scored + 1;
  end loop;

  return query select count_scored;
end;
$$ language plpgsql security definer;


-- =========================================================
-- 5. League leaderboards: real totals, ranked. security_invoker means
--    this view respects the RLS on prediction_scores/league_members
--    underneath it, so it can't be used to peek at a league you're not
--    in. Needs Postgres 15+, which Supabase runs by default. If your
--    project is on an old fork this clause would need dropping and the
--    privacy guarantee would need rechecking.
-- =========================================================
create or replace view league_leaderboard
with (security_invoker = true) as
select
  lm.league_id,
  lm.user_id,
  coalesce(sum(ps.total_points), 0) as total_points,
  count(ps.id) as fixtures_scored
from league_members lm
left join prediction_scores ps on ps.user_id = lm.user_id
group by lm.league_id, lm.user_id;

grant select on league_leaderboard to authenticated;

-- =========================================================
-- 6. A minimal profiles table. Without this, a leaderboard can only
--    show anonymous user IDs, which isn't usable. Populated
--    automatically on signup via a trigger (the standard Supabase
--    pattern for this). Visibility is scoped to league-mates only,
--    not every signed-in user can see everyone else's email, only
--    people who actually share a league with them.
-- =========================================================
create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

drop policy if exists "own profile and league mates visible" on profiles;
create policy "own profile and league mates visible" on profiles
  for select using (
    auth.uid() = user_id
    or exists (
      select 1 from league_members lm1
      join league_members lm2 on lm1.league_id = lm2.league_id
      where lm1.user_id = auth.uid() and lm2.user_id = profiles.user_id
    )
  );

create or replace function handle_new_user() returns trigger as $$
begin
  insert into public.profiles (user_id, email) values (new.id, new.email)
  on conflict (user_id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Backfill for anyone who signed up before this migration ran.
insert into profiles (user_id, email)
select id, email from auth.users
on conflict (user_id) do nothing;

-- ---------- moderation and display names ----------
alter table profiles add column if not exists display_name text;

create or replace function handle_new_user() returns trigger as $$
declare
  v_name text;
begin
  v_name := 'Tiger' || (1000 + floor(random() * 9000))::int;
  insert into public.profiles (user_id, email, display_name) values (new.id, new.email, v_name)
  on conflict (user_id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

-- Backfill anyone who already signed up before this existed.
update profiles set display_name = 'Tiger' || (1000 + floor(random() * 9000))::int
where display_name is null;

-- =========================================================
-- 2. Blocked words: a real table, not hardcoded logic, so you can
--    add or remove terms later without needing a code change.
-- =========================================================
create table if not exists blocked_words (
  word text primary key
);

alter table blocked_words enable row level security;
-- No public policies at all, nobody needs to read this table directly,
-- it's only ever checked from inside the trigger function below, which
-- runs with elevated privileges regardless of RLS.

-- A conservative starter list: common profanity. Add more anytime with:
-- insert into blocked_words (word) values ('newword') on conflict do nothing;
insert into blocked_words (word) values
  ('fuck'),('shit'),('bitch'),('cunt'),('bastard'),('asshole'),
  ('dick'),('piss'),('twat'),('wanker'),('bollocks'),('slut'),('whore')
on conflict (word) do nothing;

create or replace function contains_blocked_word(input text) returns boolean as $$
  select exists(
    select 1 from blocked_words
    where lower(input) like '%' || word || '%'
  );
$$ language sql stable;

-- =========================================================
-- 3. Enforcement: triggers, not just app-level checks, so this can't
--    be bypassed by calling the API directly instead of using the site.
-- =========================================================
create or replace function block_explicit_league_name() returns trigger as $$
begin
  if contains_blocked_word(new.name) then
    raise exception 'That league name isn''t allowed, please pick something else.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists check_league_name on leagues;
create trigger check_league_name
  before insert or update on leagues
  for each row execute function block_explicit_league_name();

create or replace function block_explicit_display_name() returns trigger as $$
begin
  if new.display_name is not null and contains_blocked_word(new.display_name) then
    raise exception 'That name isn''t allowed, please pick something else.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists check_display_name on profiles;
create trigger check_display_name
  before insert or update on profiles
  for each row execute function block_explicit_display_name();

-- =========================================================
-- 4. Let users manage their own display name, separate from the
--    general "own profile visible" policy, this specifically allows
--    self-updates (display_name only, in practice, since email/user_id
--    updates from the client would be pointless, nothing stops
--    someone technically sending other fields, but nothing reads them
--    if changed this way, and RLS still confines this to their own row).
-- =========================================================
drop policy if exists "users update own display name" on profiles;
create policy "users update own display name" on profiles
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- automatic prediction carry-over ----------
alter table predictions add column if not exists is_auto_carried boolean not null default false;

create or replace function carry_over_predictions() returns void as $$
declare
  fx record;
  usr record;
  last_pred record;
begin
  -- Any fixture whose lock time (75 minutes before kick-off) falls
  -- within the next 2 hours, and hasn't kicked off yet. The 2-hour
  -- window plus running this every 30 minutes means every fixture
  -- gets caught reliably before it locks, without carrying over
  -- absurdly early.
  for fx in
    select * from fixtures
    where status = 'Scheduled'
      and (match_date + coalesce(kickoff_time, '00:00')::time - interval '75 minutes')
        between now() and now() + interval '2 hours'
  loop
    -- Every user who's predicted anything before, but not yet this fixture
    for usr in
      select distinct user_id from predictions
      where user_id not in (select user_id from predictions where fixture_id = fx.id)
    loop
      select * into last_pred from predictions
      where user_id = usr.user_id and fixture_id <> fx.id
      order by updated_at desc limit 1;

      if found then
        insert into predictions (user_id, fixture_id, formation, lineup, hull_score, opponent_score, scorers, is_auto_carried, updated_at)
        values (usr.user_id, fx.id, last_pred.formation, last_pred.lineup, last_pred.hull_score, last_pred.opponent_score, last_pred.scorers, true, now())
        on conflict (user_id, fixture_id) do nothing;
      end if;
    end loop;
  end loop;
end;
$$ language plpgsql security definer;

-- Schedules the job to check every 30 minutes. If this line fails or
-- you'd rather manage it visually, skip it and use the Cron dashboard
-- instead (Dashboard → Integrations → Cron → New Job → Database
-- Function -> carry_over_predictions -> every 30 minutes), same effect,
-- friendlier interface.
select cron.schedule('carry-over-predictions', '*/30 * * * *', 'select carry_over_predictions();');

-- ---------- predictor formations (admin-editable) ----------
create table if not exists predictor_formations (
  name text primary key,
  gk int not null default 1,
  df int not null,
  mf int not null,
  fw int not null,
  sort_order int not null default 0
);

alter table predictor_formations enable row level security;

drop policy if exists "public read predictor formations" on predictor_formations;
create policy "public read predictor formations" on predictor_formations
  for select using (true);
-- No public write policy, only the admin-action edge function (using
-- the service role) can add, edit, or remove formations.

insert into predictor_formations (name, gk, df, mf, fw, sort_order) values
  ('4-4-2', 1, 4, 4, 2, 1),
  ('4-3-3', 1, 4, 3, 3, 2),
  ('4-2-3-1', 1, 4, 5, 1, 3),
  ('3-5-2', 1, 3, 5, 2, 4),
  ('5-3-2', 1, 5, 3, 2, 5)
on conflict (name) do nothing;

-- ---------- prediction reminder emails ----------
create table if not exists prediction_reminders_sent (
  user_id uuid not null references auth.users(id) on delete cascade,
  fixture_id uuid not null references fixtures(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (user_id, fixture_id)
);

alter table prediction_reminders_sent enable row level security;
-- No public policies, only the edge function (service role) ever
-- touches this table.


-- ---------- player season points (aggregated from scoring breakdowns) ----------
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

-- ---------- pitch layout (cosmetic, admin-adjustable) ----------
create table if not exists pitch_layout_settings (
  position text primary key check (position in ('GK','DF','MF','FW')),
  y_position int not null check (y_position between 0 and 100)
);

alter table pitch_layout_settings enable row level security;

drop policy if exists "public read pitch layout" on pitch_layout_settings;
create policy "public read pitch layout" on pitch_layout_settings
  for select using (true);

insert into pitch_layout_settings (position, y_position) values
  ('GK', 8), ('DF', 26), ('MF', 52), ('FW', 82)
on conflict (position) do nothing;

-- ---------- player ratings ----------
create table if not exists player_ratings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  matchday_id uuid not null references matchdays(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  rating int not null check (rating between 1 and 10),
  comment text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, matchday_id, player_id)
);

alter table player_ratings enable row level security;

drop policy if exists "public read ratings" on player_ratings;
create policy "public read ratings" on player_ratings
  for select using (true);

drop policy if exists "users manage own ratings" on player_ratings;
create policy "users manage own ratings" on player_ratings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Same moderation already protecting league names and display names,
-- reused here rather than duplicated.
create or replace function check_rating_comment() returns trigger as $$
begin
  if new.comment is not null and contains_blocked_word(new.comment) then
    raise exception 'That comment isn''t allowed, try rephrasing it.';
  end if;
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists rating_comment_check on player_ratings;
create trigger rating_comment_check before insert or update on player_ratings
  for each row execute function check_rating_comment();

-- One row per player per matchday: the average and how many ratings
-- it's built from. security_invoker so it correctly respects the
-- "public read" policy above rather than bypassing it.
create or replace view player_rating_averages
with (security_invoker = true) as
select
  matchday_id, player_id,
  round(avg(rating)::numeric, 1) as average_rating,
  count(*) as rating_count
from player_ratings
group by matchday_id, player_id;

-- Ratings are meant to be a genuinely public feature, but the
-- existing profiles table is restricted to your own profile and
-- league-mates (and also stores email, which must never become
-- public). This view exposes only the display name, to anyone,
-- without touching that restriction or the email column at all.
create or replace view public_display_names as
select user_id, display_name from profiles;

grant select on public_display_names to anon, authenticated;

-- ---------- achievements and status ----------
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


-- ---------- expanded achievement set ----------
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
