-- Run this once in the Supabase SQL editor. Adds four wildcards, each
-- usable once per season (right now, effectively once ever, since this
-- is the first season this system has tracked). Only one can be active
-- on any single prediction, enforced structurally by this being a
-- single column, not a set of flags.

alter table predictions add column if not exists wildcard text
  check (wildcard in ('double', 'clean_sheet', 'hat_trick_hero', 'reverse_score'));

alter table prediction_scores add column if not exists clean_sheet_points int not null default 0;
alter table prediction_scores add column if not exists wildcard_applied text;

-- Which football season a date falls in, as a label like '2026-27'.
-- Seasons run August to May, so July onward counts as the start of a
-- new season, matches how the Premier League itself labels seasons.
-- Used to enforce "once per season" per wildcard.
create or replace function football_season(d date) returns text as $$
  select case when extract(month from d) >= 7
    then extract(year from d)::text || '-' || right((extract(year from d)::int + 1)::text, 2)
    else (extract(year from d)::int - 1)::text || '-' || right(extract(year from d)::text, 2)
  end;
$$ language sql immutable;

-- Rewritten scoring function, same core logic as before, with each
-- wildcard's effect layered on afterward, only when that prediction
-- actually used it.
create or replace function calculate_fixture_scores(fid uuid)
returns table(scored_count int) as $$
declare
  md matchdays%rowtype;
  pred predictions%rowtype;
  pos_pts int;
  score_pts int;
  scorer_pts int;
  first_scorer_pts int;
  clean_sheet_pts int;
  lineup_item jsonb;
  first_scorer_id text;
  scorer_position text;
  scorer_item jsonb;
  count_scored int := 0;
  correct_positions jsonb;
  score_result text;
  predicted_scorer_detail jsonb;
  first_scorer_detail jsonb;
  breakdown_json jsonb;
  gk_df_count int;
  total_pts int;
begin
  select * into md from matchdays where fixture_id = fid order by created_at desc limit 1;
  if not found then
    raise exception 'No matchday result found for this fixture yet, enter one in admin first.';
  end if;

  first_scorer_id := md.goalscorers->0->>'player_id';

  for pred in select * from predictions where fixture_id = fid loop
    pos_pts := 0;
    correct_positions := '[]'::jsonb;
    gk_df_count := 0;

    for lineup_item in select jsonb_array_elements(pred.lineup) loop
      if lineup_item->>'slot' in ('GK','DF') then
        gk_df_count := gk_df_count + 1;
      end if;
      if exists (
        select 1 from jsonb_array_elements(md.lineup) a_item
        where a_item->>'player_id' = lineup_item->>'player_id'
          and a_item->>'is_sub' = 'false'
          and slot_to_broad_position(a_item->>'slot') = lineup_item->>'slot'
      ) then
        pos_pts := pos_pts + 2;
        correct_positions := correct_positions || jsonb_build_object(
          'player_id', lineup_item->>'player_id',
          'first_name', lineup_item->>'first_name',
          'last_name', lineup_item->>'last_name',
          'slot', lineup_item->>'slot'
        );
      end if;
    end loop;

    -- Score / result points. Reverse Score also counts a mirrored
    -- exact match (predicted 1-0, actual finished 0-1) as a full hit.
    score_pts := 0;
    score_result := 'none';
    if pred.hull_score is not null and pred.opponent_score is not null
       and md.hull_score is not null and md.opponent_score is not null then
      if pred.hull_score = md.hull_score and pred.opponent_score = md.opponent_score then
        score_pts := 10; score_result := 'exact';
      elsif pred.wildcard = 'reverse_score' and pred.hull_score = md.opponent_score and pred.opponent_score = md.hull_score then
        score_pts := 10; score_result := 'exact_reversed';
      elsif sign(pred.hull_score - pred.opponent_score) = sign(md.hull_score - md.opponent_score) then
        score_pts := 5; score_result := 'result';
      end if;
    end if;

    -- Goalscorer points. Hat-trick Hero triples both categories.
    scorer_pts := 0;
    first_scorer_pts := 0;
    predicted_scorer_detail := null;
    first_scorer_detail := null;

    for scorer_item in select jsonb_array_elements(pred.scorers) loop
      select p.position into scorer_position from players p where p.id = (scorer_item->>'player_id')::uuid;

      if scorer_item->>'type' = 'predicted' then
        if exists (select 1 from jsonb_array_elements(md.goalscorers) g where g->>'player_id' = scorer_item->>'player_id') then
          scorer_pts := scorer_pts + case scorer_position
            when 'GK' then 10 when 'DF' then 10 when 'MF' then 7 when 'FW' then 5 else 0 end;
          predicted_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name',
            'hit', true, 'points', case scorer_position when 'GK' then 10 when 'DF' then 10 when 'MF' then 7 when 'FW' then 5 else 0 end
          );
        else
          predicted_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name', 'hit', false, 'points', 0
          );
        end if;
      end if;

      if scorer_item->>'type' = 'first' then
        if scorer_item->>'player_id' = first_scorer_id then
          first_scorer_pts := first_scorer_pts + case scorer_position
            when 'GK' then 20 when 'DF' then 20 when 'MF' then 15 when 'FW' then 10 else 0 end;
          first_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name',
            'hit', true, 'points', case scorer_position when 'GK' then 20 when 'DF' then 20 when 'MF' then 15 when 'FW' then 10 else 0 end
          );
        else
          first_scorer_detail := jsonb_build_object(
            'player_id', scorer_item->>'player_id', 'first_name', scorer_item->>'first_name', 'last_name', scorer_item->>'last_name', 'hit', false, 'points', 0
          );
        end if;
      end if;
    end loop;

    if pred.wildcard = 'hat_trick_hero' then
      scorer_pts := scorer_pts * 3;
      first_scorer_pts := first_scorer_pts * 3;
    end if;

    -- Clean Sheet Wildcard: 5 points per goalkeeper/defender predicted,
    -- only if Hull actually kept a clean sheet.
    clean_sheet_pts := 0;
    if pred.wildcard = 'clean_sheet' and md.opponent_score = 0 then
      clean_sheet_pts := gk_df_count * 5;
    end if;

    total_pts := pos_pts + score_pts + scorer_pts + first_scorer_pts + clean_sheet_pts;

    -- Double Points Wildcard: doubles everything this prediction earned.
    if pred.wildcard = 'double' then
      total_pts := total_pts * 2;
    end if;

    breakdown_json := jsonb_build_object(
      'correct_positions', correct_positions,
      'score_result', score_result,
      'predicted_hull_score', pred.hull_score,
      'predicted_opponent_score', pred.opponent_score,
      'actual_hull_score', md.hull_score,
      'actual_opponent_score', md.opponent_score,
      'predicted_scorer', predicted_scorer_detail,
      'first_scorer', first_scorer_detail,
      'wildcard', pred.wildcard,
      'clean_sheet_points', clean_sheet_pts
    );

    insert into prediction_scores (prediction_id, user_id, fixture_id, position_points, score_points, scorer_points, first_scorer_points, clean_sheet_points, wildcard_applied, total_points, breakdown, calculated_at)
    values (pred.id, pred.user_id, fid, pos_pts, score_pts, scorer_pts, first_scorer_pts, clean_sheet_pts, pred.wildcard, total_pts, breakdown_json, now())
    on conflict (user_id, fixture_id) do update set
      position_points = excluded.position_points,
      score_points = excluded.score_points,
      scorer_points = excluded.scorer_points,
      first_scorer_points = excluded.first_scorer_points,
      clean_sheet_points = excluded.clean_sheet_points,
      wildcard_applied = excluded.wildcard_applied,
      total_points = excluded.total_points,
      breakdown = excluded.breakdown,
      calculated_at = now();

    count_scored := count_scored + 1;
  end loop;

  return query select count_scored;
end;
$$ language plpgsql security definer;
