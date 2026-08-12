// supabase/functions/send-prediction-reminders/index.ts
//
// Triggered on a schedule (pg_cron + pg_net, see migrate_add_prediction_reminders.sql)
// rather than by a person or admin action. Checks for fixtures approaching
// their lock time, and emails anyone signed up who hasn't predicted it yet,
// a nudge before the auto-carry-over takes over, not a replacement for it.
//
// Deploy with: supabase functions deploy send-prediction-reminders --no-verify-jwt
// Required secrets (same ones already set for send-post-email):
//   RESEND_API_KEY
//   RESEND_FROM
//   SITE_URL

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (_req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM") || "TIGERDLE <onboarding@resend.dev>";
  const siteUrl = Deno.env.get("SITE_URL") || "https://example.github.io/tigerdle";
  if (!resendKey) {
    return new Response(JSON.stringify({ ok: false, error: "RESEND_API_KEY not set" }), { status: 500 });
  }

  // Fixtures locking in the next 3 to 4 hours, a window wide enough that
  // the every-30-minutes schedule reliably catches each fixture exactly
  // once, without emailing people so early it's easy to forget by kickoff.
  const { data: fixtures, error: fxErr } = await supabase.from("fixtures").select("*").eq("status", "Scheduled");
  if (fxErr) return new Response(JSON.stringify({ ok: false, error: fxErr.message }), { status: 500 });

  const now = Date.now();
  const dueFixtures = (fixtures || []).filter((fx: any) => {
    const kickoff = new Date(`${fx.match_date}T${fx.kickoff_time || "00:00"}`).getTime();
    const lockTime = kickoff - 75 * 60000;
    const hoursUntilLock = (lockTime - now) / 3600000;
    return hoursUntilLock > 3 && hoursUntilLock <= 4;
  });

  if (!dueFixtures.length) {
    return new Response(JSON.stringify({ ok: true, remindersSent: 0, note: "No fixtures in the reminder window right now" }));
  }

  let totalSent = 0;

  for (const fixture of dueFixtures) {
    const { data: predicted } = await supabase.from("predictions").select("user_id").eq("fixture_id", fixture.id);
    const predictedIds = new Set((predicted || []).map((p: any) => p.user_id));

    const { data: alreadyReminded } = await supabase.from("prediction_reminders_sent").select("user_id").eq("fixture_id", fixture.id);
    const remindedIds = new Set((alreadyReminded || []).map((r: any) => r.user_id));

    const { data: profiles } = await supabase.from("profiles").select("user_id, email");
    const toRemind = (profiles || []).filter((p: any) => p.email && !predictedIds.has(p.user_id) && !remindedIds.has(p.user_id));

    if (!toRemind.length) continue;

    const predictUrl = `${siteUrl}/predictor.html`;
    function emailHtml() {
      return `
      <div style="font-family:Arial,sans-serif; max-width:560px; margin:0 auto; color:#14110d;">
        <div style="height:8px; background:repeating-linear-gradient(-35deg,#f5a300 0 12px,#14110d 12px 24px);"></div>
        <div style="padding:24px;">
          <p style="font-family:monospace; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#c67f00;">TIGERDLE</p>
          <h1 style="font-size:22px; margin:6px 0 14px;">Hull City vs ${escapeHtml(fixture.opponent)}: you haven't predicted yet</h1>
          <p style="font-size:14px; line-height:1.6; color:#333;">
            Predictions close 75 minutes before kick-off. If you don't set one, your last team carries forward automatically,
            but it's more fun to actually make the call yourself.
          </p>
          <p><a href="${predictUrl}" style="display:inline-block; margin-top:10px; background:#f5a300; color:#14110d; padding:10px 18px; border-radius:999px; text-decoration:none; font-weight:bold; font-size:13px;">Predict now</a></p>
        </div>
      </div>`;
    }
    function escapeHtml(s: string) {
      return String(s || "").replace(/[&<>"']/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[m] as string));
    }

    const chunks: typeof toRemind[] = [];
    for (let i = 0; i < toRemind.length; i += 100) chunks.push(toRemind.slice(i, i + 100));

    const remindedThisRun: string[] = [];
    for (const chunk of chunks) {
      const batch = chunk.map((p: any) => ({
        from, to: [p.email], subject: `Hull vs ${fixture.opponent}: predictions close soon`, html: emailHtml(),
      }));
      const res = await fetch("https://api.resend.com/emails/batch", {
        method: "POST",
        headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify(batch),
      });
      if (res.ok) {
        chunk.forEach((p: any) => remindedThisRun.push(p.user_id));
      } else {
        console.error("Resend batch failed:", await res.text());
      }
    }

    if (remindedThisRun.length) {
      await supabase.from("prediction_reminders_sent").insert(
        remindedThisRun.map((uid) => ({ user_id: uid, fixture_id: fixture.id }))
      );
      totalSent += remindedThisRun.length;
    }
  }

  return new Response(JSON.stringify({ ok: true, remindersSent: totalSent, fixturesChecked: dueFixtures.length }));
});
