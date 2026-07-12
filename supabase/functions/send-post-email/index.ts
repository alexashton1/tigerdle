// supabase/functions/send-post-email/index.ts
//
// Called by admin-action whenever a post is published. Loads the post and
// every subscribed email address, then sends via Resend's batch endpoint.
// Not meant to be called from the browser directly (no CORS needed) —
// admin-action calls it server-to-server with the service role key.
//
// Deploy with: supabase functions deploy send-post-email --no-verify-jwt
// Required secrets:
//   RESEND_API_KEY
//   RESEND_FROM        — e.g. "TIGERDLE <news@yourdomain.com>" (domain must
//                         be verified in Resend)
//   SITE_URL           — e.g. https://yourname.github.io/tigerdle

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  let postId: string;
  try {
    const body = await req.json();
    postId = body.postId;
    if (!postId) throw new Error("postId required");
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "postId required" }), { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: post, error: postErr } = await supabase.from("posts").select("*").eq("id", postId).single();
  if (postErr || !post) {
    return new Response(JSON.stringify({ ok: false, error: "Post not found" }), { status: 404 });
  }

  const { data: subs, error: subErr } = await supabase
    .from("subscribers")
    .select("email, unsubscribe_token")
    .eq("subscribed", true);
  if (subErr) {
    return new Response(JSON.stringify({ ok: false, error: subErr.message }), { status: 500 });
  }
  if (!subs || !subs.length) {
    return new Response(JSON.stringify({ ok: true, sent: 0, note: "No subscribers yet" }));
  }

  const siteUrl = Deno.env.get("SITE_URL") || "https://example.github.io/tigerdle";
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM") || "TIGERDLE <onboarding@resend.dev>";
  if (!resendKey) {
    return new Response(JSON.stringify({ ok: false, error: "RESEND_API_KEY not set" }), { status: 500 });
  }

  const postUrl = `${siteUrl}/post.html?slug=${encodeURIComponent(post.slug)}`;

  function emailHtml(unsubUrl: string) {
    return `
    <div style="font-family:Arial,sans-serif; max-width:560px; margin:0 auto; color:#14110d;">
      <div style="height:8px; background:repeating-linear-gradient(-35deg,#f5a300 0 12px,#14110d 12px 24px);"></div>
      <div style="padding:24px;">
        <p style="font-family:monospace; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#c67f00;">TIGERDLE</p>
        <h1 style="font-size:24px; margin:6px 0 14px;">${escapeHtml(post.title)}</h1>
        <p style="font-size:14px; line-height:1.6; color:#333;">${escapeHtml(post.excerpt || "")}</p>
        <p><a href="${postUrl}" style="display:inline-block; margin-top:10px; background:#f5a300; color:#14110d; padding:10px 18px; border-radius:999px; text-decoration:none; font-weight:bold; font-size:13px;">Read the full post</a></p>
        <p style="margin-top:32px; font-size:11px; color:#888;">
          You're getting this because you subscribed at TIGERDLE.
          <a href="${unsubUrl}" style="color:#888;">Unsubscribe</a>
        </p>
      </div>
    </div>`;
  }

  function escapeHtml(s: string) {
    return String(s || "").replace(/[&<>"']/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[m] as string));
  }

  // Resend batch endpoint takes up to 100 emails per call
  const chunks: typeof subs[] = [];
  for (let i = 0; i < subs.length; i += 100) chunks.push(subs.slice(i, i + 100));

  let sent = 0;
  for (const chunk of chunks) {
    const batch = chunk.map((s) => ({
      from,
      to: [s.email],
      subject: post.title,
      html: emailHtml(`${Deno.env.get("SUPABASE_URL")}/functions/v1/unsubscribe?token=${s.unsubscribe_token}`),
    }));
    const res = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(batch),
    });
    if (res.ok) sent += chunk.length;
    else console.error("Resend batch failed:", await res.text());
  }

  return new Response(JSON.stringify({ ok: true, sent, total: subs.length }));
});
