-- =========================================================
-- TIGERDLE — Supabase schema
-- Run this once in the Supabase SQL editor for a new project.
-- =========================================================

create extension if not exists pgcrypto;

-- ---------- players ----------
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  position text not null check (position in ('GK','DF','MF','FW')),
  nationality text not null default 'Unknown',
  era text not null default 'Current Squad',
  age int,
  birth_date date,
  appearances int,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table players enable row level security;

drop policy if exists "public read active players" on players;
create policy "public read active players" on players
  for select using (true);
-- No insert/update/delete policies for anon/authenticated: all writes go
-- through the admin-action edge function using the service role key.

-- ---------- posts ----------
create table if not exists posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  slug text not null unique,
  excerpt text,
  body_md text not null default '',
  published boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now()
);

alter table posts enable row level security;

drop policy if exists "public read published posts" on posts;
create policy "public read published posts" on posts
  for select using (published = true);
-- Writes go through admin-action (service role) so drafts stay hidden
-- from anon reads while still being manageable from the admin panel
-- (the admin panel reads posts via the same anon key, so drafts would
-- normally be invisible to it too — the admin page instead relies on
-- the fact that only you know the passphrase to reach admin-action,
-- and can extend this policy to authenticated if you add real login later).

-- ---------- subscribers ----------
create table if not exists subscribers (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  subscribed boolean not null default true,
  unsubscribe_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table subscribers enable row level security;

drop policy if exists "public can subscribe" on subscribers;
create policy "public can subscribe" on subscribers
  for insert with check (true);
-- No select/update/delete for anon — reading the list, sending email,
-- and unsubscribing all happen through edge functions with the service
-- role key, so email addresses are never exposed to the browser.

-- ---------- goals ("Guess the Opponent" puzzles) ----------
create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  image_url text not null,
  opponent text not null,
  competition text,
  match_date date,
  puzzle_date date unique,
  created_at timestamptz not null default now()
);

alter table goals enable row level security;

drop policy if exists "public read goals" on goals;
create policy "public read goals" on goals
  for select using (true);

-- ---------- storage bucket for goal photos ----------
insert into storage.buckets (id, name, public)
values ('goal-images', 'goal-images', true)
on conflict (id) do nothing;

-- Public can read (bucket is public); only the service role (used inside
-- the admin-action edge function) can write, so uploads always go through
-- the passphrase check.
drop policy if exists "public read goal images" on storage.objects;
create policy "public read goal images" on storage.objects
  for select using (bucket_id = 'goal-images');
