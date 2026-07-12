// supabase/functions/unsubscribe/index.ts
//
// Public GET endpoint used by the unsubscribe link in emails.
// Deploy with: supabase functions deploy unsubscribe --no-verify-jwt

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function page(message: string) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><title>TIGERDLE</title>
  <style>body{font-family:sans-serif;background:#14110d;color:#f2ead9;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;}
  div{max-width:360px;padding:20px;} a{color:#f5a300;}</style></head>
  <body><div><h2>🐯 TIGERDLE</h2><p>${message}</p></div></body></html>`;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const token = url.searchParams.get("token");
  if (!token) {
    return new Response(page("Missing unsubscribe token."), { status: 400, headers: { "Content-Type": "text/html" } });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error } = await supabase.from("subscribers").update({ subscribed: false }).eq("unsubscribe_token", token);
  if (error) {
    return new Response(page("Something went wrong — try again later."), { status: 500, headers: { "Content-Type": "text/html" } });
  }
  return new Response(page("You're unsubscribed. No more emails from us."), { headers: { "Content-Type": "text/html" } });
});
