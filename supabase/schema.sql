-- =========================================================
-- TIGERDLE — Supabase schema
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
-- normally be invisible to it too — the admin page instead relies on
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
-- No select/update/delete for anon — reading the list, sending email,
-- and unsubscribing all happen through edge functions with the service
-- role key, so email addresses are never exposed to the browser.

-- ---------- user_stats (accounts — separate from the rest of the site,
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
-- it — nobody else, including other signed-in users, can query someone
-- else's specific pick through this table. The aggregate views below
-- are the only sanctioned way anyone sees "what other people predicted",
-- and they only ever expose counts, never who predicted what.
drop policy if exists "users read own predictions" on predictions;
create policy "users read own predictions" on predictions
  for select using (auth.uid() = user_id);

-- Locking: a fixture stops accepting new or changed predictions once
-- it's kicked off. Enforced here, server-side, not just hidden in the
-- UI — a direct API call after kickoff is rejected by the database
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
-- Each of these only ever returns counts grouped by fixture — never a
-- user_id, never which specific person picked what. That's what makes
-- it safe to expose to any visitor, signed in or not.

create or replace view prediction_slot_counts as
select
  p.fixture_id,
  p.formation,
  lineup_item.slot,
  lineup_item.player_id,
  lineup_item.first_name,
  lineup_item.last_name,
  count(*) as votes
from predictions p,
  jsonb_to_recordset(p.lineup) as lineup_item(player_id uuid, first_name text, last_name text, slot text)
group by p.fixture_id, p.formation, lineup_item.slot, lineup_item.player_id, lineup_item.first_name, lineup_item.last_name;

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
-- Summer Time. Not a problem in practice — predictions realistically
-- close well before kickoff anyway — but worth knowing if you ever see
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
-- you created it. A private league you don't belong to is invisible —
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
drop policy if exists "members see other members" on league_members;
create policy "members see other members" on league_members
  for select using (
    league_id in (select league_id from league_members where user_id = auth.uid())
  );

-- Direct self-join only works for public leagues — joining a private
-- one requires the code, enforced by the function below instead.
drop policy if exists "users join public leagues directly" on league_members;
create policy "users join public leagues directly" on league_members
  for insert with check (
    auth.uid() = user_id
    and exists (select 1 from leagues l where l.id = league_members.league_id and l.is_public = true)
  );

-- Creating a league: picks a name, generates a unique code, creates the
-- league, and joins the creator as its first member — all in one call.
create or replace function create_league(league_name text, make_public boolean default false)
returns table(league_id uuid, league_code text) as $$
declare
  new_code text;
  new_league_id uuid;
begin
  loop
    new_code := upper(substr(md5(random()::text), 1, 6));
    exit when not exists (select 1 from leagues where code = new_code);
  end loop;
  insert into leagues (name, code, is_public, created_by)
    values (league_name, new_code, make_public, auth.uid())
    returning id into new_league_id;
  insert into league_members (league_id, user_id) values (new_league_id, auth.uid());
  return query select new_league_id, new_code;
end;
$$ language plpgsql security definer;

-- Joining a private league by code: looks the league up by its exact
-- code (bypassing the "can't browse private leagues" rule, safely,
-- since you have to already know the code) and adds you as a member.
-- Wrong code just raises an error, no information leaked either way.
create or replace function join_league_by_code(join_code text)
returns table(league_id uuid, league_name text) as $$
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

-- Seeds one public league so there's always at least one to see —
-- "Overall", open to anyone, no code needed.
insert into leagues (name, code, is_public, created_by)
select 'Overall', 'OVERALL', true, null
where not exists (select 1 from leagues where code = 'OVERALL');

-- ---------- scoring system ----------
-- 1. Lock predictions 75 minutes before kickoff, not at kickoff —
--    matching when official team sheets actually come out.
-- =========================================================
create or replace function fixture_not_started(fid uuid) returns boolean as $$
  select coalesce(
    (select (match_date + coalesce(kickoff_time, '00:00')::time - interval '75 minutes') > now()
     from fixtures where id = fid),
    false
  );
$$ language sql stable;
-- (Same BST/UTC caveat as before — team sheets close 75 minutes before
-- your entered kickoff time, compared against the server's UTC clock.)

-- =========================================================
-- 2. Link a matchday to its fixture, and record who scored and in
--    what order — needed to know both "any scorer" and "first scorer".
-- =========================================================
alter table matchdays add column if not exists fixture_id uuid references fixtures(id) on delete set null;
alter table matchdays add column if not exists goalscorers jsonb not null default '[]'::jsonb;
-- goalscorers shape: [{player_id, first_name, last_name}, ...] — index 0
-- is the first goal of the match, in order after that.

create index if not exists matchdays_fixture_idx on matchdays(fixture_id);

-- =========================================================
-- 3. Where computed scores live — one row per user per fixture,
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
  calculated_at timestamptz not null default now(),
  unique(user_id, fixture_id)
);

alter table prediction_scores enable row level security;

-- Own scores are always visible. League-mates' scores are visible too,
-- once calculated — that's the "view each other's results" part —
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
-- prediction behind that score (not just the number) — again, only
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
--    you've entered a matchday's real lineup, score, and goalscorers —
--    deliberately not automatic, so nothing gets scored off an
--    incomplete result.
-- =========================================================
create or replace function calculate_fixture_scores(fid uuid)
returns table(scored_count int) as $$
declare
  md matchdays%rowtype;
  pred predictions%rowtype;
  pos_pts int;
  score_pts int;
  scorer_pts int;
  first_scorer_pts int;
  predicted_slot text;
  actual_slot text;
  scorer jsonb;
  first_scorer_id text;
  scorer_position text;
  count_scored int := 0;
begin
  select * into md from matchdays where fixture_id = fid order by created_at desc limit 1;
  if not found then
    raise exception 'No matchday result found for this fixture yet — enter one in admin first.';
  end if;

  first_scorer_id := md.goalscorers->0->>'player_id';

  for pred in select * from predictions where fixture_id = fid loop
    pos_pts := 0;
    -- 2 points for every predicted player who started in that exact slot
    for predicted_slot, actual_slot in
      select p_item->>'player_id', a_item->>'slot'
      from jsonb_array_elements(pred.lineup) p_item
      left join jsonb_array_elements(md.lineup) a_item
        on a_item->>'player_id' = p_item->>'player_id' and a_item->>'is_sub' = 'false'
      where a_item->>'slot' = p_item->>'slot'
    loop
      pos_pts := pos_pts + 2;
    end loop;

    -- Score / result points
    score_pts := 0;
    if pred.hull_score is not null and pred.opponent_score is not null
       and md.hull_score is not null and md.opponent_score is not null then
      if pred.hull_score = md.hull_score and pred.opponent_score = md.opponent_score then
        score_pts := 10;
      elsif sign(pred.hull_score - pred.opponent_score) = sign(md.hull_score - md.opponent_score) then
        score_pts := 5;
      end if;
    end if;

    -- Goalscorer points
    scorer_pts := 0;
    first_scorer_pts := 0;
    for scorer in select jsonb_array_elements(pred.scorers) loop
      select p.position into scorer_position from players p where p.id = (scorer->>'player_id')::uuid;
      if scorer->>'type' = 'predicted' and exists (
        select 1 from jsonb_array_elements(md.goalscorers) g where g->>'player_id' = scorer->>'player_id'
      ) then
        scorer_pts := scorer_pts + case scorer_position
          when 'GK' then 10 when 'DF' then 10 when 'MF' then 7 when 'FW' then 5 else 0 end;
      end if;
      if scorer->>'type' = 'first' and scorer->>'player_id' = first_scorer_id then
        first_scorer_pts := first_scorer_pts + case scorer_position
          when 'GK' then 20 when 'DF' then 20 when 'MF' then 15 when 'FW' then 10 else 0 end;
      end if;
    end loop;

    insert into prediction_scores (prediction_id, user_id, fixture_id, position_points, score_points, scorer_points, first_scorer_points, total_points, calculated_at)
    values (pred.id, pred.user_id, fid, pos_pts, score_pts, scorer_pts, first_scorer_pts, pos_pts + score_pts + scorer_pts + first_scorer_pts, now())
    on conflict (user_id, fixture_id) do update set
      position_points = excluded.position_points,
      score_points = excluded.score_points,
      scorer_points = excluded.scorer_points,
      first_scorer_points = excluded.first_scorer_points,
      total_points = excluded.total_points,
      calculated_at = now();

    count_scored := count_scored + 1;
  end loop;

  return query select count_scored;
end;
$$ language plpgsql security definer;

-- =========================================================
-- 5. League leaderboards — real totals, ranked. security_invoker means
--    this view respects the RLS on prediction_scores/league_members
--    underneath it, so it can't be used to peek at a league you're not
--    in. Needs Postgres 15+, which Supabase runs by default — if your
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
-- 6. A minimal profiles table — without this, a leaderboard can only
--    show anonymous user IDs, which isn't usable. Populated
--    automatically on signup via a trigger (the standard Supabase
--    pattern for this). Visibility is scoped to league-mates only —
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
