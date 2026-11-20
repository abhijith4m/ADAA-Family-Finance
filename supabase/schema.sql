-- ADAA Family Finance — Supabase schema and access policies
-- Run this entire file once in Supabase Dashboard > SQL Editor.
-- Uses household-level isolation, Auth users, and Row Level Security.

create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 100),
  owner_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','entry')),
  created_at timestamptz not null default now(),
  unique (household_id, user_id),
  unique (user_id)
);

create index if not exists household_members_user_id_idx on public.household_members(user_id);
create index if not exists household_members_household_id_idx on public.household_members(household_id);

create table if not exists public.household_data (
  household_id uuid primary key references public.households(id) on delete cascade,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_data enable row level security;

create schema if not exists private;

create or replace function private.is_household_member(p_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id
      and m.user_id = (select auth.uid())
  );
$$;

create or replace function private.is_household_admin(p_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id
      and m.user_id = (select auth.uid())
      and m.role = 'admin'
  );
$$;

revoke all on function private.is_household_member(uuid) from public, anon;
revoke all on function private.is_household_admin(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_household_member(uuid) to authenticated;
grant execute on function private.is_household_admin(uuid) to authenticated;

-- Clear old policies if this script is re-run.
drop policy if exists households_member_select on public.households;
drop policy if exists household_members_self_or_admin_select on public.household_members;
drop policy if exists household_data_member_select on public.household_data;

create policy households_member_select
  on public.households for select to authenticated
  using (private.is_household_member(id));

create policy household_members_self_or_admin_select
  on public.household_members for select to authenticated
  using (user_id = (select auth.uid()) or private.is_household_admin(household_id));

create policy household_data_member_select
  on public.household_data for select to authenticated
  using (private.is_household_member(household_id));

-- No direct table writes from browser clients. Writes go through validated RPCs.
grant usage on schema public to authenticated;
revoke all on public.households from public, anon, authenticated;
revoke all on public.household_members from public, anon, authenticated;
revoke all on public.household_data from public, anon, authenticated;
grant select on public.households, public.household_members, public.household_data to authenticated;

create or replace function public.create_household(p_name text, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  if p_name is null or char_length(trim(p_name)) < 1 or char_length(trim(p_name)) > 100 then
    raise exception 'Household name must be between 1 and 100 characters';
  end if;
  if jsonb_typeof(coalesce(p_data, '{}'::jsonb)) <> 'object' then
    raise exception 'Household data must be a JSON object';
  end if;
  if exists (select 1 from public.household_members m where m.user_id = (select auth.uid())) then
    raise exception 'This user is already linked to a household';
  end if;

  insert into public.households(name, owner_id)
  values (trim(p_name), (select auth.uid()))
  returning id into v_household_id;

  insert into public.household_members(household_id, user_id, role)
  values (v_household_id, (select auth.uid()), 'admin');

  insert into public.household_data(household_id, data, updated_by)
  values (v_household_id, coalesce(p_data, '{}'::jsonb), (select auth.uid()));

  return v_household_id;
end;
$$;

create or replace function public.save_household_data(
  p_household_id uuid,
  p_expected_updated_at timestamptz,
  p_data jsonb
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_current_data jsonb;
  v_current_updated_at timestamptz;
  v_new_transactions jsonb;
  v_item jsonb;
  v_saved_data jsonb;
  v_new_updated_at timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  select m.role into v_role
  from public.household_members m
  where m.household_id = p_household_id and m.user_id = (select auth.uid());
  if v_role is null then
    raise exception 'Household membership required';
  end if;
  if jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data->'transactions') <> 'array' then
    raise exception 'Invalid ADAA data payload';
  end if;

  select d.data, d.updated_at into v_current_data, v_current_updated_at
  from public.household_data d
  where d.household_id = p_household_id
  for update;
  if not found then
    raise exception 'Household data record not found';
  end if;
  if p_expected_updated_at is null or v_current_updated_at is distinct from p_expected_updated_at then
    raise exception 'ADAA_CONFLICT: household data changed since this device loaded it' using errcode = '40001';
  end if;

  if v_role = 'entry' then
    -- Entry users can append new transactions only. They cannot alter/remove
    -- existing transactions or replace budgets, accounts, goals, bills or loans.
    if (p_data - 'transactions') is distinct from (v_current_data - 'transactions') then
      raise exception 'Entry access may only add transactions';
    end if;
    v_new_transactions := p_data->'transactions';
    if exists (
      select 1 from jsonb_array_elements(v_new_transactions) as tx(value)
      where jsonb_typeof(tx.value) <> 'object'
         or nullif(tx.value->>'id', '') is null
         or coalesce(tx.value->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         or tx.value->>'type' not in ('Expense','Income','Transfer')
         or case
              when coalesce(tx.value->>'amount', '') ~ '^[0-9]+(\.[0-9]+)?$'
              then (tx.value->>'amount')::numeric <= 0
              else true
            end
    ) then
      raise exception 'A transaction has invalid fields';
    end if;
    for v_item in select value from jsonb_array_elements(coalesce(v_current_data->'transactions', '[]'::jsonb)) as x(value)
    loop
      if not exists (
        select 1 from jsonb_array_elements(v_new_transactions) as n(value)
        where n.value->>'id' = v_item->>'id' and n.value = v_item
      ) then
        raise exception 'Entry access cannot edit or delete existing transactions';
      end if;
    end loop;
    if exists (
      select 1 from (
        select value->>'id' as tx_id
        from jsonb_array_elements(v_new_transactions) as x(value)
        group by value->>'id'
        having count(*) > 1 or (value->>'id') is null
      ) duplicates
    ) then
      raise exception 'Transaction IDs must be present and unique';
    end if;
    v_saved_data := v_current_data || jsonb_build_object('transactions', v_new_transactions);
  else
    -- Admin members can update the full household dataset.
    v_saved_data := p_data;
  end if;

  update public.household_data
  set data = v_saved_data,
      updated_at = clock_timestamp(),
      updated_by = (select auth.uid())
  where household_id = p_household_id
  returning updated_at into v_new_updated_at;

  return v_new_updated_at;
end;
$$;

revoke all on function public.create_household(text, jsonb) from public, anon;
revoke all on function public.save_household_data(uuid, timestamptz, jsonb) from public, anon;
grant execute on function public.create_household(text, jsonb) to authenticated;
grant execute on function public.save_household_data(uuid, timestamptz, jsonb) to authenticated;

-- Add a new invited Auth user to an existing household from the SQL Editor:
-- insert into public.household_members (household_id, user_id, role)
-- values ('<HOUSEHOLD_UUID>', '<AUTH_USER_UUID>', 'entry');
-- Use role 'admin' only for a trusted household administrator.

