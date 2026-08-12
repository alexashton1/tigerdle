-- Run this once in the Supabase SQL editor. Sets up the "you haven't
-- predicted yet" reminder emails, a nudge before the auto-carry-over
-- takes over, not a replacement for it.

-- Tracks who's already been reminded for which fixture, so the
-- every-30-minutes check never emails the same person twice for the
-- same match.
create table if not exists prediction_reminders_sent (
  user_id uuid not null references auth.users(id) on delete cascade,
  fixture_id uuid not null references fixtures(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (user_id, fixture_id)
);

alter table prediction_reminders_sent enable row level security;
-- No public policies, only the edge function (service role) ever
-- touches this table.

-- =========================================================
-- Scheduling: before running this part, replace YOUR-PROJECT-REF with
-- your actual project ref (the same one in your Supabase URL, e.g.
-- yiiijduxagjkmbzrhoaj) in the url below. --no-verify-jwt on the
-- function deploy means no Authorization header is actually required,
-- so this doesn't need your service role key pasted into a cron job.
-- =========================================================
select cron.schedule(
  'send-prediction-reminders',
  '*/30 * * * *',
  $$
  select net.http_post(
    url := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/send-prediction-reminders',
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  $$
);
