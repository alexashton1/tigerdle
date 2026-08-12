-- Run this FIRST if you hit "function football_season(date) does not
-- exist", it means that function never made it onto this database,
-- even though the achievements system quietly assumed it had. This
-- creates it if missing (harmless to re-run even if it already exists
-- identical definition, so nothing changes if it's already there).
--
-- After running this, retry backfill_achievements.sql.

create or replace function football_season(d date) returns text as $$
  select case when extract(month from d) >= 7
    then extract(year from d)::text || '-' || right((extract(year from d)::int + 1)::text, 2)
    else (extract(year from d)::int - 1)::text || '-' || right(extract(year from d)::text, 2)
  end;
$$ language sql immutable;
