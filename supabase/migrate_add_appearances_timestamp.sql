-- Run this once in the Supabase SQL editor. Adds a timestamp that records
-- when a player's appearances count was last updated, so the admin panel
-- can show "as of [date]" instead of a bare number with no context.
-- Safe to run even if already applied.

alter table players add column if not exists appearances_updated_at timestamptz;

-- Backfill: anyone who already has an appearances number gets "now" as a
-- starting point, so existing data isn't shown as if it's never been set.
update players set appearances_updated_at = now()
where appearances is not null and appearances_updated_at is null;
