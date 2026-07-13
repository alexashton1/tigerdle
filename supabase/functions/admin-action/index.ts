// supabase/functions/admin-action/index.ts
//
// Single gatekeeper for every admin write in TIGERDLE. The browser never
// gets write access to the database directly — every insert/update/delete
// for players, posts and goals goes through this function, which checks
// the passphrase against a server-side secret before touching anything.
//
// Deploy with: supabase functions deploy admin-action --no-verify-jwt
// Required secrets (supabase secrets set ...):
//   ADMIN_PASSPHRASE   — the phrase you type into the admin panel
//   SITE_URL           — e.g. https://yourname.github.io/tigerdle (used in emails)
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

      case "add_player": {
        const p = payload || {};
        if (!p.first_name || !p.last_name || !p.position) {
          return json({ ok: false, error: "first_name, last_name and position are required" }, 400);
        }
        const { data, error } = await supabase.from("players").insert({
          first_name: p.first_name,
          last_name: p.last_name,
          position: p.position,
          nationality: p.nationality || "Unknown",
          era: p.era || "Current Squad",
          age: p.age ?? null,
          active: p.active !== false,
        }).select().single();
        if (error) throw error;
        return json({ ok: true, data });
      }

      case "bulk_add_players": {
        const p = payload || {};
        const list = Array.isArray(p.players) ? p.players : [];
        if (!list.length) return json({ ok: false, error: "No players provided" }, 400);

        const rows = [];
        const errors: string[] = [];
        for (const [i, row] of list.entries()) {
          if (!row.first_name || !row.last_name || !row.position) {
            errors.push(`Row ${i + 1}: missing first name, last name, or position`);
            continue;
          }
          if (!["GK", "DF", "MF", "FW"].includes(row.position)) {
            errors.push(`Row ${i + 1}: invalid position "${row.position}"`);
            continue;
          }
          rows.push({
            first_name: row.first_name,
            last_name: row.last_name,
            position: row.position,
            nationality: row.nationality || "Unknown",
            era: row.era || "Current Squad",
            age: row.age ?? null,
            active: true,
          });
        }
        if (!rows.length) return json({ ok: false, error: `No valid rows. ${errors.join("; ")}` }, 400);

        const { data, error } = await supabase.from("players").insert(rows).select();
        if (error) throw error;
        return json({ ok: true, data: { inserted: data.length, skipped: errors } });
      }

      case "update_player": {
        const p = payload || {};
        if (!p.id) return json({ ok: false, error: "id is required" }, 400);
        const patch: Record<string, unknown> = {};
        for (const k of ["first_name", "last_name", "position", "nationality", "era", "age", "active"]) {
          if (k in p) patch[k] = p[k];
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
