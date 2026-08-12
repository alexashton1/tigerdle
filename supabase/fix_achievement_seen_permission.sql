-- Run this once in the Supabase SQL editor. Fixes the achievement
-- notification repeating on every page. The table only ever had a
-- read policy, so the "mark this as seen" update from the browser was
-- being silently blocked by the database every time. This adds the
-- missing policy: a user can update only their own achievement rows
-- (needed for the seen flag), never anyone else's, and never able to
-- insert new achievements this way, those still only ever come from
-- calculate_achievements() itself.

drop policy if exists "users can mark own achievements seen" on user_achievements;
create policy "users can mark own achievements seen" on user_achievements
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
