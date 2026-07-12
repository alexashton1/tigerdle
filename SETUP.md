# TIGERDLE — setup runbook

Everything works with dummy data out of the box (the game falls back to a
bundled player list). This is what turns it into the full live site: a
real player database, a blog with email delivery, and a passphrase-gated
admin panel.

## 1. Create the Supabase project

1. New project at supabase.com — same flow as Steamer/Docket.
2. In the SQL editor, paste and run `supabase/schema.sql` in full.
3. Settings → API: copy the **Project URL** and **anon public key**.
4. In `assets/supabase-client.js`, replace `SUPABASE_URL` and
   `SUPABASE_ANON_KEY` with those two values.

## 2. Deploy the edge functions

Needs the Supabase CLI (`npm i -g supabase`), logged in and linked to the project.

```bash
cd supabase
supabase functions deploy admin-action --no-verify-jwt
supabase functions deploy send-post-email --no-verify-jwt
supabase functions deploy unsubscribe --no-verify-jwt
```

`--no-verify-jwt` is needed because these are called with the public anon
key (or no auth at all for unsubscribe), not a logged-in Supabase user —
the passphrase check inside `admin-action` is what actually gates writes.

## 3. Set secrets

```bash
supabase secrets set ADMIN_PASSPHRASE="choose-something-only-you-know"
supabase secrets set SITE_URL="https://alexashton1.github.io/tigerdle"
supabase secrets set RESEND_API_KEY="re_xxx"
supabase secrets set RESEND_FROM="TIGERDLE <news@yourdomain.com>"
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically
for edge functions — nothing to do there.

Pick a real passphrase, not a placeholder — it's the only thing standing
between the public internet and your database writes. Treat it like a
password; don't post it anywhere, including in this repo.

## 4. Resend

1. Sign up at resend.com, verify a sending domain (or use their shared
   `onboarding@resend.dev` sender to start, no domain needed, though
   deliverability is better with your own domain).
2. Grab an API key, set it as `RESEND_API_KEY` above.
3. `RESEND_FROM` must use a verified domain once you move off the shared sender.

## 5. Deploy the frontend

This is a static site — same pattern as your other GitHub Pages tools:

```bash
git init
git add .
git commit -m "TIGERDLE"
git remote add origin https://github.com/alexashton1/tigerdle.git
git push -u origin main
```

Then enable GitHub Pages on the repo (Settings → Pages → deploy from
`main` branch, root folder). Don't commit the `supabase/` folder's secrets
anywhere — there aren't any in this repo (they live in Supabase), but keep
it that way.

## 6. First admin login

Go to `/admin.html` on your deployed site (it's not linked from anywhere
public), enter your passphrase, and:

- Add your first signings — or leave the bundled list as-is, it'll keep
  working until you add real rows.
- Write and publish a first post to test the email flow.
- Upload a goal photo you own the rights to, for Guess the Opponent.

## Notes

- **Everything is content you control.** Nothing here scrapes or displays
  real match photography I don't have rights to — the goal-guess images
  are only ever ones you upload yourself.
- **Nationalities marked "Unknown"** in the bundled data are ones I wasn't
  confident enough in to state as fact. Worth checking and filling in.
- **No real user accounts.** The passphrase model is deliberately simple.
  If you ever want proper login (e.g. to let a co-admin in without sharing
  the phrase), swap it for Supabase Auth email/password — the RLS policies
  are already written to expect all writes to come through the edge
  function, so that's a contained change to `admin-action` plus adding a
  login page.
