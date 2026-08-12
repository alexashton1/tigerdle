-- Run this once in the Supabase SQL editor. Automatically carries a
-- user's most recent prediction forward onto the next fixture if they
-- haven't set one themselves, so forgetting doesn't mean a blank week.
-- Never overwrites an active choice: if someone's already predicted
-- the fixture themselves, this leaves it alone entirely.

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
