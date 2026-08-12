-- Run this once in the Supabase SQL editor. This is the scoring system
-- release, everything needed to go from "predictions exist" to "leagues
-- have real points." Safe to run even if some pieces already exist.

-- =========================================================
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

create or replace function calculate_fixture_scores(fid uuid)
returns table(scored_count int) as $$
declare
  md matchdays%rowtype;
  pred predictions%rowtype;
  pos_pts int;
  score_pts int;
  scorer_pts int;
  first_scorer_pts int;
  lineup_item jsonb;
  first_scorer_id text;
  scorer_position text;
  first_scorer_position text;
  scorer_item jsonb;
  count_scored int := 0;
  correct_positions jsonb;
  score_result text;
  predicted_scorer_detail jsonb;
  first_scorer_detail jsonb;
  breakdown_json jsonb;
  predicted_scorer_item jsonb;
  first_scorer_item jsonb;
begin
  select * into md from matchdays where fixture_id = fid order by created_at desc limit 1;
  if not found then
    raise exception 'No matchday result found for this fixture yet, enter one in admin first.';
  end if;

  first_scorer_id := md.goalscorers->0->>'player_id';

  for pred in select * from predictions where fixture_id = fid loop
    pos_pts := 0;
    correct_positions := '[]'::jsonb;

    -- 2 points for every predicted player who started in that exact slot,
    -- and record who, by name, for the breakdown view.
    for lineup_item in select jsonb_array_elements(pred.lineup) loop
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

    -- Score / result points
    score_pts := 0;
    score_result := 'none';
    if pred.hull_score is not null and pred.opponent_score is not null
       and md.hull_score is not null and md.opponent_score is not null then
      if pred.hull_score = md.hull_score and pred.opponent_score = md.opponent_score then
        score_pts := 10; score_result := 'exact';
      elsif sign(pred.hull_score - pred.opponent_score) = sign(md.hull_score - md.opponent_score) then
        score_pts := 5; score_result := 'result';
      end if;
    end if;

    -- Goalscorer points, with breakdown detail for each
    scorer_pts := 0;
    first_scorer_pts := 0;
    predicted_scorer_detail := null;
    first_scorer_detail := null;

    for scorer_item in select jsonb_array_elements(pred.scorers) loop
      select p.position into scorer_position from players p where p.id = (scorer_item->>'player_id')::uuid;

      if scorer_item->>'type' = 'predicted' then
        predicted_scorer_item := scorer_item;
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
        first_scorer_item := scorer_item;
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

    breakdown_json := jsonb_build_object(
      'correct_positions', correct_positions,
      'score_result', score_result,
      'predicted_hull_score', pred.hull_score,
      'predicted_opponent_score', pred.opponent_score,
      'actual_hull_score', md.hull_score,
      'actual_opponent_score', md.opponent_score,
      'predicted_scorer', predicted_scorer_detail,
      'first_scorer', first_scorer_detail
    );

    insert into prediction_scores (prediction_id, user_id, fixture_id, position_points, score_points, scorer_points, first_scorer_points, total_points, breakdown, calculated_at)
    values (pred.id, pred.user_id, fid, pos_pts, score_pts, scorer_pts, first_scorer_pts, pos_pts + score_pts + scorer_pts + first_scorer_pts, breakdown_json, now())
    on conflict (user_id, fixture_id) do update set
      position_points = excluded.position_points,
      score_points = excluded.score_points,
      scorer_points = excluded.scorer_points,
      first_scorer_points = excluded.first_scorer_points,
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
