-- Household Budget · Supabase schema
-- Run once in Supabase: SQL Editor > New query > paste > Run.

create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Household',
  invite_code text unique not null default upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 6)),
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  earner_index int not null default 0,
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

-- One shared document per household + one private document per member.
create table if not exists public.docs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  owner uuid references auth.users(id) on delete cascade,
  kind text not null check (kind in ('shared', 'private')),
  data jsonb not null default '{}'::jsonb,
  version int not null default 0,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  check ((kind = 'shared' and owner is null) or (kind = 'private' and owner is not null))
);
create unique index if not exists docs_one_shared on public.docs (household_id) where kind = 'shared';
create unique index if not exists docs_one_private on public.docs (household_id, owner) where kind = 'private';

-- Card QR codes and bank logos (kept out of the main document so saves stay small).
create table if not exists public.images (
  household_id uuid not null references public.households(id) on delete cascade,
  key text not null,
  sig text not null,
  data text not null,
  updated_at timestamptz not null default now(),
  primary key (household_id, key)
);

-- Helper: is the signed-in user a member of this household?
create or replace function public.is_member(h uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.members where household_id = h and user_id = auth.uid());
$$;

alter table public.households enable row level security;
alter table public.members enable row level security;
alter table public.docs enable row level security;
alter table public.images enable row level security;

drop policy if exists hh_select on public.households;
create policy hh_select on public.households for select using (public.is_member(id));

drop policy if exists mem_select on public.members;
create policy mem_select on public.members for select using (public.is_member(household_id));

-- Shared doc: every member. Private doc: only its owner. This is enforced by the database.
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select
  using (public.is_member(household_id) and (kind = 'shared' or owner = auth.uid()));
drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert
  with check (public.is_member(household_id) and (kind = 'shared' or owner = auth.uid()));
drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update
  using (public.is_member(household_id) and (kind = 'shared' or owner = auth.uid()))
  with check (public.is_member(household_id) and (kind = 'shared' or owner = auth.uid()));

drop policy if exists img_all on public.images;
create policy img_all on public.images for all
  using (public.is_member(household_id)) with check (public.is_member(household_id));

-- Create a household; the creator becomes earner #0.
create or replace function public.create_household(p_name text, p_display text)
returns public.households language plpgsql security definer set search_path = public as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  insert into households(name) values (coalesce(nullif(p_name, ''), 'Household')) returning * into h;
  insert into members(household_id, user_id, display_name, earner_index) values (h.id, auth.uid(), p_display, 0);
  insert into docs(household_id, kind) values (h.id, 'shared');
  insert into docs(household_id, owner, kind) values (h.id, auth.uid(), 'private');
  return h;
end $$;

-- Join with the 6-character invite code; the partner becomes earner #1.
create or replace function public.join_household(p_code text, p_display text)
returns public.households language plpgsql security definer set search_path = public as $$
declare h public.households; n int;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select * into h from households where invite_code = upper(trim(p_code));
  if h.id is null then raise exception 'BAD_CODE'; end if;
  select count(*) into n from members where household_id = h.id;
  if not exists (select 1 from members where household_id = h.id and user_id = auth.uid()) then
    if n >= 2 then raise exception 'HOUSEHOLD_FULL'; end if;
    insert into members(household_id, user_id, display_name, earner_index) values (h.id, auth.uid(), p_display, n);
    insert into docs(household_id, owner, kind) values (h.id, auth.uid(), 'private') on conflict do nothing;
  end if;
  return h;
end $$;

-- Save with a version check so two phones never overwrite each other silently.
create or replace function public.save_doc(p_id uuid, p_data jsonb, p_base int)
returns int language plpgsql security invoker set search_path = public as $$
declare nv int;
begin
  update docs set data = p_data, version = version + 1, updated_by = auth.uid(), updated_at = now()
   where id = p_id and version = p_base
   returning version into nv;
  if nv is null then return -1; end if;
  return nv;
end $$;

grant execute on function public.create_household(text, text) to authenticated;
grant execute on function public.join_household(text, text) to authenticated;
grant execute on function public.save_doc(uuid, jsonb, int) to authenticated;

-- Live updates between phones.
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;
