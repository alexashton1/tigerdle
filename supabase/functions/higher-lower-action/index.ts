// supabase/functions/higher-lower-action/index.ts
//
// Handles saving a Higher or Lower run, for both signed-in players and
// guests, and claiming a guest's run onto a real account if they sign up
// later the same day. Deployed WITH standard JWT verification (no
// --no-verify-jwt flag), same reasoning as squad-spin-action: needs a
// caller's real, verified identity when there is one, not a passphrase.
// A logged-out visitor still reaches this fine, since the browser's
// Supabase client sends the anon key as a valid (if low-privilege)
// bearer token; this function just treats that case as "no real user"
// rather than rejecting it outright.
//
// Deploy with: supabase functions deploy higher-lower-action

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, authorization",
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
  const { action, payload } = body || {};

  const authHeader = req.headers.get("Authorization") || "";
  const anonClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: userData } = await anonClient.auth.getUser();
  const realUserId: string | null = userData?.user?.id ?? null;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    switch (action) {
      // Saves today's streak, for a real user or a guest. Only overwrites
      // an existing streak for the day if the new one is actually higher,
      // so unlimited attempts (for signed-in players) never let a worse
      // retry knock out a better earlier one.
      case "save_score": {
        const p = payload || {};
        if (typeof p.streak !== "number" || !p.players_seen) {
          return json({ ok: false, error: "streak and players_seen are required" }, 400);
        }
        const mode = ["standard", "modern"].includes(p.mode) ? p.mode : "standard";
        const statType = ["appearances", "career_goals"].includes(p.stat_type) ? p.stat_type : "appearances";
        const today = new Date().toISOString().slice(0, 10);

        if (realUserId) {
          const { data: existing } = await supabase
            .from("higher_lower_scores")
            .select("streak")
            .eq("user_id", realUserId)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .eq("stat_type", statType)
            .maybeSingle();
          if (existing && existing.streak >= p.streak) {
            return json({ ok: true, data: { saved: false, bestStreakToday: existing.streak } });
          }
          const { error } = await supabase.from("higher_lower_scores").upsert({
            user_id: realUserId, guest_token: null, guest_label: null,
            puzzle_date: today, mode, stat_type: statType, streak: p.streak, players_seen: p.players_seen,
          }, { onConflict: "user_id,puzzle_date,mode,stat_type" });
          if (error) throw error;
          return json({ ok: true, data: { saved: true, bestStreakToday: p.streak } });
        }

        // Guest path: identified by a token their own browser generated
        // and kept, not a real account. Deliberately still mode-only for
        // the daily limit, same reasoning as Squad Spin's difficulty
        // split: the limit exists to encourage signing up, not to
        // multiply into four separate free attempts.
        if (!p.guest_token) return json({ ok: false, error: "guest_token is required when not signed in" }, 400);
        const { data: existingGuest } = await supabase
          .from("higher_lower_scores")
          .select("streak")
          .eq("guest_token", p.guest_token)
          .eq("puzzle_date", today)
          .eq("mode", mode)
          .maybeSingle();
        if (existingGuest && existingGuest.streak >= p.streak) {
          return json({ ok: true, data: { saved: false, bestStreakToday: existingGuest.streak } });
        }
        const { error } = await supabase.from("higher_lower_scores").upsert({
          user_id: null, guest_token: p.guest_token, guest_label: p.guest_label || "Guest",
          puzzle_date: today, mode, stat_type: statType, streak: p.streak, players_seen: p.players_seen,
        }, { onConflict: "guest_token,puzzle_date,mode" });
        if (error) throw error;
        return json({ ok: true, data: { saved: true, bestStreakToday: p.streak } });
      }

      // Reassigns today's guest run(s) onto the caller's real account, the
      // moment they sign in or sign up. Checks both modes separately,
      // since a guest could have played Standard and Modern today before
      // signing in, and both should transfer.
      case "claim_guest_score": {
        if (!realUserId) return json({ ok: false, error: "Sign in required to claim a score" }, 401);
        const p = payload || {};
        if (!p.guest_token) return json({ ok: false, error: "guest_token is required" }, 400);
        const today = new Date().toISOString().slice(0, 10);
        const claimedByMode: Record<string, number> = {};

        for (const mode of ["standard", "modern"]) {
          const { data: guestRow } = await supabase
            .from("higher_lower_scores")
            .select("id, streak, stat_type")
            .eq("guest_token", p.guest_token)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .is("user_id", null)
            .maybeSingle();
          if (!guestRow) continue;

          const { data: ownRow } = await supabase
            .from("higher_lower_scores")
            .select("id, streak")
            .eq("user_id", realUserId)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .eq("stat_type", guestRow.stat_type)
            .maybeSingle();

          if (!ownRow) {
            const { error } = await supabase
              .from("higher_lower_scores")
              .update({ user_id: realUserId, guest_token: null, guest_label: null })
              .eq("id", guestRow.id);
            if (error) throw error;
            claimedByMode[mode] = guestRow.streak;
          } else if (guestRow.streak > ownRow.streak) {
            await supabase.from("higher_lower_scores").delete().eq("id", ownRow.id);
            const { error } = await supabase
              .from("higher_lower_scores")
              .update({ user_id: realUserId, guest_token: null, guest_label: null })
              .eq("id", guestRow.id);
            if (error) throw error;
            claimedByMode[mode] = guestRow.streak;
          } else {
            await supabase.from("higher_lower_scores").delete().eq("id", guestRow.id);
          }
        }
        return json({ ok: true, data: { claimedByMode } });
      }

      default:
        return json({ ok: false, error: `Unknown action: ${action}` }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
