// supabase/functions/squad-spin-action/index.ts
//
// Handles saving a Squad Spin score, for both signed-in players and
// guests, and claiming a guest's score onto a real account if they sign
// up later the same day. Deployed WITH standard JWT verification (no
// --no-verify-jwt flag), unlike admin-action, since this one needs to
// know a caller's real, verified identity when they have one, not a
// passphrase. A logged-out visitor still reaches this fine, since the
// browser's Supabase client sends the anon key as a valid (if
// low-privilege) bearer token; this function just treats that case as
// "no real user" rather than rejecting it outright.
//
// Deploy with: supabase functions deploy squad-spin-action

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

const TARGET_SCORE = 1904;

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

  // Figure out who's actually calling, if anyone. The anon key alone
  // decodes fine but carries no real user, which is expected for guests.
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
      // Saves today's score, for a real user or a guest. Only overwrites
      // an existing score for the day if the new one is actually higher,
      // so unlimited attempts (for signed-in players) never let a worse
      // retry knock out a better earlier one.
      case "save_score": {
        const p = payload || {};
        if (typeof p.score !== "number" || !p.squad) {
          return json({ ok: false, error: "score and squad are required" }, 400);
        }
        const mode = ["normal", "modern"].includes(p.mode) ? p.mode : "normal";
        const difficulty = ["easy", "medium", "hard"].includes(p.difficulty) ? p.difficulty : "medium";
        const today = new Date().toISOString().slice(0, 10);

        if (realUserId) {
          const { data: existing } = await supabase
            .from("squad_spin_scores")
            .select("score")
            .eq("user_id", realUserId)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .eq("difficulty", difficulty)
            .maybeSingle();
          if (existing && existing.score >= p.score) {
            return json({ ok: true, data: { saved: false, bestScoreToday: existing.score } });
          }
          const { error } = await supabase.from("squad_spin_scores").upsert({
            user_id: realUserId, guest_token: null, guest_label: null,
            puzzle_date: today, mode, difficulty, score: p.score, squad: p.squad,
          }, { onConflict: "user_id,puzzle_date,mode,difficulty" });
          if (error) throw error;
          return json({ ok: true, data: { saved: true, bestScoreToday: p.score } });
        }

        // Guest path: identified by a token their own browser generated
        // and kept, not a real account.
        if (!p.guest_token) return json({ ok: false, error: "guest_token is required when not signed in" }, 400);
        const { data: existingGuest } = await supabase
          .from("squad_spin_scores")
          .select("score")
          .eq("guest_token", p.guest_token)
          .eq("puzzle_date", today)
          .eq("mode", mode)
          .maybeSingle();
        if (existingGuest && existingGuest.score >= p.score) {
          return json({ ok: true, data: { saved: false, bestScoreToday: existingGuest.score } });
        }
        const { error } = await supabase.from("squad_spin_scores").upsert({
          user_id: null, guest_token: p.guest_token, guest_label: p.guest_label || "Guest",
          puzzle_date: today, mode, difficulty, score: p.score, squad: p.squad,
        }, { onConflict: "guest_token,puzzle_date,mode" });
        if (error) throw error;
        return json({ ok: true, data: { saved: true, bestScoreToday: p.score } });
      }

      // Reassigns today's guest row (if any) onto the caller's real
      // Reassigns today's guest row(s) onto the caller's real account, the
      // moment they sign in or sign up. Requires a real, verified caller,
      // a guest_token alone proves nothing on its own. Checks both modes
      // separately, since a guest could have played Normal and Modern
      // today before signing in, and both should transfer.
      case "claim_guest_score": {
        if (!realUserId) return json({ ok: false, error: "Sign in required to claim a score" }, 401);
        const p = payload || {};
        if (!p.guest_token) return json({ ok: false, error: "guest_token is required" }, 400);
        const today = new Date().toISOString().slice(0, 10);
        const claimedByMode: Record<string, number> = {};

        for (const mode of ["normal", "modern"]) {
          const { data: guestRow } = await supabase
            .from("squad_spin_scores")
            .select("id, score, difficulty")
            .eq("guest_token", p.guest_token)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .is("user_id", null)
            .maybeSingle();
          if (!guestRow) continue;

          const { data: ownRow } = await supabase
            .from("squad_spin_scores")
            .select("id, score")
            .eq("user_id", realUserId)
            .eq("puzzle_date", today)
            .eq("mode", mode)
            .eq("difficulty", guestRow.difficulty)
            .maybeSingle();

          if (!ownRow) {
            const { error } = await supabase
              .from("squad_spin_scores")
              .update({ user_id: realUserId, guest_token: null, guest_label: null })
              .eq("id", guestRow.id);
            if (error) throw error;
            claimedByMode[mode] = guestRow.score;
          } else if (guestRow.score > ownRow.score) {
            await supabase.from("squad_spin_scores").delete().eq("id", ownRow.id);
            const { error } = await supabase
              .from("squad_spin_scores")
              .update({ user_id: realUserId, guest_token: null, guest_label: null })
              .eq("id", guestRow.id);
            if (error) throw error;
            claimedByMode[mode] = guestRow.score;
          } else {
            await supabase.from("squad_spin_scores").delete().eq("id", guestRow.id);
          }
        }
        return json({ ok: true, data: { claimedByMode } });
      }

      // Hardcore: one attempt a day, win or lose, requires a real
      // account since there's no guest support for this mode, tracking
      // wins over time only means something with a persistent identity.
      case "save_hardcore_attempt": {
        if (!realUserId) return json({ ok: false, error: "Sign in required to play Hardcore" }, 401);
        const p = payload || {};
        if (typeof p.won !== "boolean" || typeof p.final_score !== "number" || !p.squad) {
          return json({ ok: false, error: "won, final_score and squad are required" }, 400);
        }
        const today = new Date().toISOString().slice(0, 10);
        const { data: existing } = await supabase
          .from("squad_spin_hardcore_attempts")
          .select("id")
          .eq("user_id", realUserId)
          .eq("puzzle_date", today)
          .maybeSingle();
        if (existing) {
          return json({ ok: true, data: { saved: false, reason: "Already attempted Hardcore today" } });
        }
        const { error } = await supabase.from("squad_spin_hardcore_attempts").insert({
          user_id: realUserId, puzzle_date: today, won: p.won, final_score: p.final_score, squad: p.squad,
        });
        if (error) throw error;
        return json({ ok: true, data: { saved: true } });
      }

      default:
        return json({ ok: false, error: `Unknown action: ${action}` }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
