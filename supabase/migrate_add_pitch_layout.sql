-- Run this once in the Supabase SQL editor. Lets you tune how far down
-- the pitch each position's row sits, purely visual spacing, no effect
-- on votes, players, or predictions. Public read (needed to draw the
-- pitch for anyone viewing it), writes only via admin-action.

create table if not exists pitch_layout_settings (
  position text primary key check (position in ('GK','DF','MF','FW')),
  y_position int not null check (y_position between 0 and 100)
);

alter table pitch_layout_settings enable row level security;

drop policy if exists "public read pitch layout" on pitch_layout_settings;
create policy "public read pitch layout" on pitch_layout_settings
  for select using (true);

insert into pitch_layout_settings (position, y_position) values
  ('GK', 8), ('DF', 26), ('MF', 52), ('FW', 82)
on conflict (position) do nothing;
