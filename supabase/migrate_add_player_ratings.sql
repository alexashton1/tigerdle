-- Run this once in the Supabase SQL editor. Lets signed-in users rate
-- players after a match: a number 1-10 plus an optional short comment,
-- and shows everyone the community average alongside the official
-- rating already entered by admin. Comments go through the same
-- blocked-word moderation already protecting league and display names.

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
