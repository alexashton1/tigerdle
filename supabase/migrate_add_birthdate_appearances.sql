-- Run this once in the Supabase SQL editor. Safe to run even if you're
-- not sure whether it's already been applied — the IF NOT EXISTS guards
-- make it a no-op if the columns already exist.

alter table players add column if not exists birth_date date;
alter table players add column if not exists appearances integer;

-- Nothing else needed — existing rows just get NULL for both new columns,
-- and the site falls back to the old static age field until you fill in
-- real birth dates.
