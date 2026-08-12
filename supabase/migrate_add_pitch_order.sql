-- Run this once in the Supabase SQL editor. Adds a simple per-player
-- setting controlling their left-to-right placement within their
-- position line on any pitch view, so a winger actually shows up
-- wide, not wherever vote-count or tap-order happened to put them.
-- Lower numbers sit further left, higher further right. Leave blank
-- for anyone where it doesn't matter (goalkeepers, most defenders).

alter table players add column if not exists pitch_order int;
