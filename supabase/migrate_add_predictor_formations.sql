-- Run this once in the Supabase SQL editor. Turns the predictor's
-- formation presets into a real, admin-editable table instead of
-- something hardcoded in the code. Add, tweak, or remove formations
-- from admin without needing a code change each time.

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
