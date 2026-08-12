-- Run this once in the Supabase SQL editor. Everyone gets automatically
-- added to the "Overall" public league on signup, no more requiring
-- people to notice it and click Join themselves.

create or replace function handle_new_user() returns trigger as $$
declare
  v_name text;
  v_overall_id uuid;
begin
  v_name := 'Tiger' || (1000 + floor(random() * 9000))::int;
  insert into public.profiles (user_id, email, display_name) values (new.id, new.email, v_name)
  on conflict (user_id) do nothing;

  select id into v_overall_id from leagues where code = 'OVERALL';
  if v_overall_id is not null then
    insert into league_members (league_id, user_id) values (v_overall_id, new.id)
    on conflict (league_id, user_id) do nothing;
  end if;

  return new;
end;
$$ language plpgsql security definer;

-- Backfill everyone who signed up before this existed.
insert into league_members (league_id, user_id)
select (select id from leagues where code = 'OVERALL'), u.id
from auth.users u
where exists (select 1 from leagues where code = 'OVERALL')
on conflict (league_id, user_id) do nothing;
