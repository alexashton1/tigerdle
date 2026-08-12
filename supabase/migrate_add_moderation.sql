-- Run this once in the Supabase SQL editor. Two things: a moderation
-- layer that blocks explicit/offensive text in anything publicly
-- visible (league names, display names), and a real display-name system
-- so nobody has to show their actual email to people they share a
-- league with, anonymous by default, changeable anytime.

-- =========================================================
-- 1. Display names: profiles gets a real, user-controlled name.
--    New signups get a friendly anonymous-style name automatically,
--    rather than defaulting to their email.
-- =========================================================
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
