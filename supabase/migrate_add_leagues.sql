-- Run this once in the Supabase SQL editor. Leagues — join via code for
-- private friend groups, or join directly for public ones. A points
-- leaderboard needs the scoring engine (still not built — see the note
-- at the bottom of migrate_add_predictions.sql), so league pages will
-- show membership correctly but an honest "no scores yet" placeholder
-- until that exists.

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
