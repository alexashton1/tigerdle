// supabase/functions/admin-action/index.ts
//
// Single gatekeeper for every admin write in TIGERDLE. The browser never
// gets write access to the database directly. Every insert/update/delete
// for players, posts and goals goes through this function, which checks
// the passphrase against a server-side secret before touching anything.
//
// Deploy with: supabase functions deploy admin-action --no-verify-jwt
// Required secrets (supabase secrets set ...):
//   ADMIN_PASSPHRASE   : the phrase you type into the admin panel
//   SITE_URL           : e.g. https://yourname.github.io/tigerdle (used in emails)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const { passphrase, action, payload } = body || {};
  const expected = Deno.env.get("ADMIN_PASSPHRASE");
  if (!expected || passphrase !== expected) {
    return json({ ok: false, error: "Unauthorized" }, 401);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    switch (action) {
      case "ping": {
        return json({ ok: true, data: { pong: true } });
      }

      case "stats": {
        const { count, error } = await supabase
          .from("subscribers")
          .select("*", { count: "exact", head: true })
          .eq("subscribed", true);
        if (error) throw error;
        return json({ ok: true, data: { subscriberCount: count ?? 0 } });
      }

      case "list_subscribers": {
        const { data, error } = await supabase
          .from("subscribers")
          .select("email, subscribed, created_at")
          .order("created_at", { ascending: false });
        if (error) throw error;
        return json({ ok: true, data: { subscribers: data } });
      }

      case "export_all_data": {
        const [players, posts, goals, subscribers] = await Promise.all([
          supabase.from("players").select("*"),
          supabase.from("posts").select("*"),
          supabase.from("goals").select("*"),
          supabase.from("subscribers").select("email, subscribed, created_at"),
        ]);
        return json({
          ok: true,
          data: {
            exported_at: new Date().toISOString(),
            players: players.data || [],
            posts: posts.data || [],
            goals: goals.data || [],
            subscribers: subscribers.data || [],
          },
        });
      }

      case "add_player": {
        const p = payload || {};
        if (!p.first_name || !p.last_name || !p.position) {
          return json({ ok: false, error: "first_name, last_name and position are required" }, 400);
        }
        const { data: existing } = await supabase
          .from("players")
          .select("id")
          .ilike("first_name", p.first_name.trim())
          .ilike("last_name", p.last_name.trim())
          .limit(1);
        if (existing && existing.length) {
          return json({ ok: false, error: `${p.first_name} ${p.last_name} is already in the player pool.` }, 409);
        }
        const { data, error } = await supabase.from("players").insert({
          first_name: p.first_name,
          last_name: p.last_name,
          position: p.position,
          nationality: p.nationality || "Unknown",
          era: p.era || "Current Squad",
          age: p.age ?? null,
          birth_date: p.birth_date || null,
          appearances: p.appearances ?? null,
          appearances_updated_at: p.appearances != null ? new Date().toISOString() : null,
          active: p.active !== false,
          pitch_order: p.pitch_order ?? null,
        }).select().single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "bulk_add_players": {
        const p = payload || {};
        const list = Array.isArray(p.players) ? p.players : [];
        if (!list.length) return json({ ok: false, error: "No players provided" }, 400);

        // Existing DB players, for a case-insensitive name check
        const { data: existingPlayers } = await supabase.from("players").select("first_name, last_name");
        const existingKeys = new Set(
          (existingPlayers || []).map((r: any) => `${r.first_name.trim().toLowerCase()}|${r.last_name.trim().toLowerCase()}`)
        );

        const rows = [];
        const errors: string[] = [];
        const seenInBatch = new Set<string>();
        let duplicateCount = 0;
        for (const [i, row] of list.entries()) {
          if (!row.first_name || !row.last_name || !row.position) {
            errors.push(`Row ${i + 1}: missing first name, last name, or position`);
            continue;
          }
          if (!["GK", "DF", "MF", "FW"].includes(row.position)) {
            errors.push(`Row ${i + 1}: invalid position "${row.position}"`);
            continue;
          }
          const key = `${row.first_name.trim().toLowerCase()}|${row.last_name.trim().toLowerCase()}`;
          if (existingKeys.has(key) || seenInBatch.has(key)) {
            duplicateCount++;
            continue;
          }
          seenInBatch.add(key);
          rows.push({
            first_name: row.first_name,
            last_name: row.last_name,
            position: row.position,
            nationality: row.nationality || "Unknown",
            era: row.era || "Current Squad",
            age: row.age ?? null,
            birth_date: row.birth_date || null,
            appearances: row.appearances ?? null,
            appearances_updated_at: row.appearances != null ? new Date().toISOString() : null,
            active: true,
          });
        }
        if (!rows.length) {
          const reason = duplicateCount ? `All ${duplicateCount} row(s) were already in the pool.` : `No valid rows. ${errors.join("; ")}`;
          return json({ ok: false, error: reason }, 400);
        }

        const { data, error } = await supabase.from("players").insert(rows).select();
        if (error) throw error;
        return json({ ok: true, data: { inserted: data.length, skipped: errors, duplicatesSkipped: duplicateCount } });
      }

      case "find_duplicate_players": {
        const { data, error } = await supabase.from("players").select("*").order("created_at");
        if (error) throw error;
        const groups: Record<string, any[]> = {};
        for (const row of data || []) {
          const key = `${row.first_name.trim().toLowerCase()}|${row.last_name.trim().toLowerCase()}`;
          (groups[key] ||= []).push(row);
        }
        const duplicates = Object.values(groups).filter((g) => g.length > 1);
        return json({ ok: true, data: { duplicates } });
      }

      case "bulk_delete_players": {
        const p = payload || {};
        const ids = Array.isArray(p.ids) ? p.ids : [];
        if (!ids.length) return json({ ok: false, error: "No ids provided" }, 400);
        const { error } = await supabase.from("players").delete().in("id", ids);
        if (error) throw error;
        return json({ ok: true, data: { deleted: ids.length } });
      }

      case "bulk_update_players": {
        const p = payload || {};
        const list = Array.isArray(p.updates) ? p.updates : [];
        if (!list.length) return json({ ok: false, error: "No updates provided" }, 400);

        const { data: existingPlayers } = await supabase.from("players").select("id, first_name, last_name");
        const byName = new Map(
          (existingPlayers || []).map((r: any) => [`${r.first_name.trim().toLowerCase()}|${r.last_name.trim().toLowerCase()}`, r.id])
        );

        let updated = 0;
        const notFound: string[] = [];
        for (const row of list) {
          if (!row.first_name || !row.last_name) continue;
          const key = `${row.first_name.trim().toLowerCase()}|${row.last_name.trim().toLowerCase()}`;
          const id = byName.get(key);
          if (!id) { notFound.push(`${row.first_name} ${row.last_name}`); continue; }

          const patch: Record<string, unknown> = {};
          if (row.position) patch.position = row.position;
          if (row.nationality) patch.nationality = row.nationality;
          if (row.era) patch.era = row.era;
          if (row.age !== undefined && row.age !== null && row.age !== "") patch.age = Number(row.age);
          if (row.birth_date) patch.birth_date = row.birth_date;
          if (row.appearances !== undefined && row.appearances !== null && row.appearances !== "") {
            patch.appearances = Number(row.appearances);
            patch.appearances_updated_at = new Date().toISOString();
          }
          if (!Object.keys(patch).length) continue;

          const { error } = await supabase.from("players").update(patch).eq("id", id);
          if (!error) updated++;
        }
        return json({ ok: true, data: { updated, notFound } });
      }

      case "update_player": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const patch: Record<string, unknown> = {};
        for (const k of ["first_name", "last_name", "position", "nationality", "era", "age", "birth_date", "appearances", "active", "pitch_order"]) {
          if (k in p) patch[k] = p[k];
        }
        if ("appearances" in patch) {
          const { data: existing } = await supabase.from("players").select("appearances").eq("id", p.id).single();
          if (!existing || existing.appearances !== patch.appearances) {
            patch.appearances_updated_at = patch.appearances != null ? new Date().toISOString() : null;
          }
        }
        const { data, error } = await supabase.from("players").update(patch).eq("id", p.id).select().single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "delete_player": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const { error } = await supabase.from("players").delete().eq("id", p.id);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true } });
      }

      case "add_post": {
        const p = payload || {};
        if (!p.title || !p.slug) return json({ ok: false, error: "title and slug are required" }, 400);
        const published = !!p.published;
        const { data, error } = await supabase.from("posts").insert({
          title: p.title,
          slug: p.slug,
          excerpt: p.excerpt || "",
          body_md: p.body_md || "",
          published,
          published_at: published ? new Date().toISOString() : null,
        }).select().single();
        if (error) throw error;

        if (published) {
          await triggerPostEmail(data.id);
        }
        return json({ ok: true, data });
      }

      case "publish_post": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const { data, error } = await supabase
          .from("posts")
          .update({ published: true, published_at: new Date().toISOString() })
          .eq("id", p.id)
          .select()
          .single();
        if (error) throw error;
        await triggerPostEmail(data.id);
        return json({ ok: true, data });
      }

      case "delete_post": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const { error } = await supabase.from("posts").delete().eq("id", p.id);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true } });
      }

      case "add_goal": {
        const p = payload || {};
        if (!p.image_base64 || !p.opponent) {
          return json({ ok: false, error: "image_base64 and opponent are required" }, 400);
        }
        const match = /^data:(image\/\w+);base64,(.+)$/.exec(p.image_base64);
        if (!match) return json({ ok: false, error: "image_base64 must be a data URL" }, 400);
        const contentType = match[1];
        const ext = contentType.split("/")[1] || "jpg";
        const bytes = Uint8Array.from(atob(match[2]), (c) => c.charCodeAt(0));
        const path = `${crypto.randomUUID()}.${ext}`;

        const { error: upErr } = await supabase.storage.from("goal-images").upload(path, bytes, {
          contentType,
          upsert: false,
        });
        if (upErr) throw upErr;
        const { data: pub } = supabase.storage.from("goal-images").getPublicUrl(path);

        const { data, error } = await supabase.from("goals").insert({
          image_url: pub.publicUrl,
          opponent: p.opponent,
          competition: p.competition || null,
          match_date: p.match_date || null,
          puzzle_date: p.puzzle_date || null,
        }).select().single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "delete_goal": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const { error } = await supabase.from("goals").delete().eq("id", p.id);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true } });
      }

      case "save_fixture": {
        const p = payload || {};
        if (!p.opponent || !p.match_date) {
          return json({ ok: false, error: "opponent and match_date are required" }, 400);
        }
        const record = {
          opponent: p.opponent,
          match_date: p.match_date,
          kickoff_time: p.kickoff_time || null,
          competition: p.competition || null,
          home_away: p.home_away || null,
          status: p.status || "Scheduled",
        };
        let data, error;
        if (p.id) {
          ({ data, error } = await supabase.from("fixtures").update(record).eq("id", p.id).select().single());
        } else {
          ({ data, error } = await supabase.from("fixtures").insert(record).select().single());
        }
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "bulk_add_fixtures": {
        const p = payload || {};
        const list = Array.isArray(p.fixtures) ? p.fixtures : [];
        if (!list.length) return json({ ok: false, error: "No fixtures provided" }, 400);

        const { data: existing } = await supabase.from("fixtures").select("opponent, match_date");
        const existingKeys = new Set(
          (existing || []).map((r: any) => `${r.opponent.trim().toLowerCase()}|${r.match_date}`)
        );

        const rows = [];
        const errors: string[] = [];
        let duplicateCount = 0;
        for (const [i, row] of list.entries()) {
          if (!row.opponent || !row.match_date) {
            errors.push(`Row ${i + 1}: missing opponent or match date`);
            continue;
          }
          const key = `${row.opponent.trim().toLowerCase()}|${row.match_date}`;
          if (existingKeys.has(key)) { duplicateCount++; continue; }
          existingKeys.add(key);
          rows.push({
            opponent: row.opponent,
            match_date: row.match_date,
            kickoff_time: row.kickoff_time || null,
            competition: row.competition || null,
            home_away: row.home_away || null,
            status: row.status || "Scheduled",
          });
        }
        if (!rows.length) {
          const reason = duplicateCount ? `All ${duplicateCount} row(s) already exist.` : `No valid rows. ${errors.join("; ")}`;
          return json({ ok: false, error: reason }, 400);
        }
        const { data, error } = await supabase.from("fixtures").insert(rows).select();
        if (error) throw error;
        return json({ ok: true, data: { inserted: data.length, skipped: errors, duplicatesSkipped: duplicateCount } });
      }

      case "delete_fixture": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const { error } = await supabase.from("fixtures").delete().eq("id", p.id);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true } });
      }

      case "calculate_fixture_scores": {
        const p = payload || {};
        if (!p.fixture_id) return json({ ok: false, error: "fixture_id is required" }, 400);
        const { data, error } = await supabase.rpc("calculate_fixture_scores", { fid: p.fixture_id });
        if (error) throw error;
        const scoredCount = data?.[0]?.scored_count ?? 0;
        return json({ ok: true, data: { scoredCount } });
      }

      case "list_fixture_scores": {
        const p = payload || {};
        if (!p.fixture_id) return json({ ok: false, error: "fixture_id is required" }, 400);
        const { data: scores, error } = await supabase
          .from("prediction_scores")
          .select("*")
          .eq("fixture_id", p.fixture_id)
          .order("total_points", { ascending: false });
        if (error) throw error;
        const userIds = (scores || []).map((s: any) => s.user_id);
        const { data: profiles } = userIds.length
          ? await supabase.from("profiles").select("user_id, email, display_name").in("user_id", userIds)
          : { data: [] };
        const withNames = (scores || []).map((s: any) => {
          const profile = (profiles || []).find((pr: any) => pr.user_id === s.user_id);
          return { ...s, display_name: profile?.display_name || profile?.email || "Unknown" };
        });
        return json({ ok: true, data: { scores: withNames } });
      }

      case "override_prediction_score": {
        const p = payload || {};
        if (!p.id || p.total_points === undefined) {
          return json({ ok: false, error: "id and total_points are required" }, 400);
        }
        const { data, error } = await supabase
          .from("prediction_scores")
          .update({ total_points: p.total_points, calculated_at: new Date().toISOString() })
          .eq("id", p.id)
          .select()
          .single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "save_predictor_formation": {
        const p = payload || {};
        if (!p.name || !p.df || !p.mf || !p.fw) {
          return json({ ok: false, error: "name, df, mf, and fw are required" }, 400);
        }
        const total = 1 + Number(p.df) + Number(p.mf) + Number(p.fw);
        if (total !== 11) {
          return json({ ok: false, error: `Positions must add up to 11 including the goalkeeper. This adds up to ${total}.` }, 400);
        }
        const { data, error } = await supabase.from("predictor_formations").upsert({
          name: p.name, gk: 1, df: p.df, mf: p.mf, fw: p.fw, sort_order: p.sort_order ?? 0,
        }, { onConflict: "name" }).select().single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "delete_predictor_formation": {
        const p = payload || {};
        if (!p.name) return json({ ok: false, error: "name is required" }, 400);
        const { error } = await supabase.from("predictor_formations").delete().eq("name", p.name);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true } });
      }

      case "save_pitch_layout": {
        const p = payload || {};
        const positions = ["GK", "DF", "MF", "FW"];
        for (const pos of positions) {
          if (p[pos] === undefined || p[pos] === null || p[pos] < 0 || p[pos] > 100) {
            return json({ ok: false, error: `${pos} needs a value between 0 and 100` }, 400);
          }
        }
        for (const pos of positions) {
          const { error } = await supabase.from("pitch_layout_settings").upsert(
            { position: pos, y_position: p[pos] }, { onConflict: "position" }
          );
          if (error) throw error;
        }
        return json({ ok: true, data: { saved: true } });
      }

      case "save_matchday": {
        const p = payload || {};
        if (!p.match_date || !p.opponent || !p.formation || !Array.isArray(p.lineup) || !p.lineup.length) {
          return json({ ok: false, error: "match_date, opponent, formation and a lineup are required" }, 400);
        }

        const newIds = [...new Set(p.lineup.map((row: any) => row.player_id).filter(Boolean))];

        let previouslyCounted: string[] = [];
        if (p.id) {
          const { data: existing } = await supabase.from("matchdays").select("appearances_counted_for").eq("id", p.id).single();
          previouslyCounted = (existing?.appearances_counted_for as string[]) || [];
        }

        const newlyAdded = newIds.filter((id) => !previouslyCounted.includes(id));
        const removed = previouslyCounted.filter((id) => !newIds.includes(id));

        // Credit an appearance to anyone newly included in this matchday.
        await Promise.all(newlyAdded.map(async (playerId) => {
          const { data: player } = await supabase.from("players").select("appearances").eq("id", playerId).single();
          const current = player?.appearances ?? 0;
          await supabase.from("players").update({
            appearances: current + 1,
            appearances_updated_at: new Date().toISOString(),
          }).eq("id", playerId);
        }));

        // Undo the appearance for anyone removed from an edited matchday.
        await Promise.all(removed.map(async (playerId) => {
          const { data: player } = await supabase.from("players").select("appearances").eq("id", playerId).single();
          const current = player?.appearances ?? 0;
          await supabase.from("players").update({
            appearances: Math.max(0, current - 1),
            appearances_updated_at: new Date().toISOString(),
          }).eq("id", playerId);
        }));

        const record = {
          match_date: p.match_date,
          opponent: p.opponent,
          competition: p.competition || null,
          home_away: p.home_away || null,
          hull_score: p.hull_score ?? null,
          opponent_score: p.opponent_score ?? null,
          formation: p.formation,
          lineup: p.lineup,
          fixture_id: p.fixture_id || null,
          goalscorers: p.goalscorers || [],
          appearances_counted_for: newIds,
          updated_at: new Date().toISOString(),
        };

        let data, error;
        if (p.id) {
          ({ data, error } = await supabase.from("matchdays").update(record).eq("id", p.id).select().single());
        } else {
          ({ data, error } = await supabase.from("matchdays").insert(record).select().single());
        }
        if (error) throw error;
        return json({ ok: true, data: { matchday: data, appearancesAdded: newlyAdded.length, appearancesRemoved: removed.length } });
      }

      case "delete_matchday": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);

        const { data: existing } = await supabase.from("matchdays").select("appearances_counted_for").eq("id", p.id).single();
        const counted: string[] = (existing?.appearances_counted_for as string[]) || [];

        // Deleting a matchday undoes every appearance it credited.
        await Promise.all(counted.map(async (playerId) => {
          const { data: player } = await supabase.from("players").select("appearances").eq("id", playerId).single();
          const current = player?.appearances ?? 0;
          await supabase.from("players").update({
            appearances: Math.max(0, current - 1),
            appearances_updated_at: new Date().toISOString(),
          }).eq("id", playerId);
        }));

        const { error } = await supabase.from("matchdays").delete().eq("id", p.id);
        if (error) throw error;
        return json({ ok: true, data: { deleted: true, appearancesRemoved: counted.length } });
      }

      default:
        return json({ ok: false, error: `Unknown action: ${action}` }, 400);
    }
  } catch (err) {
    console.error(err);
    return json({ ok: false, error: err?.message || "Server error" }, 500);
  }
});

async function triggerPostEmail(postId: string) {
  try {
    await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/send-post-email`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
      },
      body: JSON.stringify({ postId }),
    });
  } catch (e) {
    console.error("Failed to trigger send-post-email:", e);
  }
}
