-- MORYA AGENCY Mobile Skin: secure admin access + atomic booking acceptance
-- Run after skin_shop_products and skin_shop_bookings exist.
-- STEP 1: Replace the UUID below with the owner's Supabase Auth user UUID.
-- Find it in Supabase Dashboard -> Authentication -> Users.
-- Never use a service_role key in the browser.

create table if not exists public.skin_shop_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.skin_shop_admins enable row level security;

-- Admin membership is readable only by the matching signed-in user.
drop policy if exists "skin shop admin reads own membership" on public.skin_shop_admins;
create policy "skin shop admin reads own membership"
on public.skin_shop_admins for select to authenticated
using (user_id = auth.uid());

-- IMPORTANT: replace 00000000-0000-0000-0000-000000000000 before running.
insert into public.skin_shop_admins(user_id)
values ('00000000-0000-0000-0000-000000000000'::uuid)
on conflict (user_id) do nothing;

-- Customers may see available designs and submit pending bookings.
alter table public.skin_shop_products enable row level security;
alter table public.skin_shop_bookings enable row level security;

drop policy if exists "skin shop customers view in-stock designs" on public.skin_shop_products;
create policy "skin shop customers view in-stock designs"
on public.skin_shop_products for select to anon, authenticated
using (active = true and stock > 0);

drop policy if exists "skin shop customers create pending booking" on public.skin_shop_bookings;
create policy "skin shop customers create pending booking"
on public.skin_shop_bookings for insert to anon, authenticated
with check (
  status = 'pending'
  and quantity = 1
  and char_length(trim(customer_name)) between 1 and 100
  and customer_phone ~ '^[0-9+ -]{8,20}$'
  and exists (
    select 1 from public.skin_shop_products p
    where p.id = product_id and p.active = true and p.stock > 0
  )
);

-- Admin can list bookings and designs, and add/restock products.
drop policy if exists "skin shop admin reads products" on public.skin_shop_products;
create policy "skin shop admin reads products"
on public.skin_shop_products for select to authenticated
using (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()));

drop policy if exists "skin shop admin adds products" on public.skin_shop_products;
create policy "skin shop admin adds products"
on public.skin_shop_products for insert to authenticated
with check (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()));

drop policy if exists "skin shop admin updates products" on public.skin_shop_products;
create policy "skin shop admin updates products"
on public.skin_shop_products for update to authenticated
using (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()))
with check (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()));

drop policy if exists "skin shop admin reads bookings" on public.skin_shop_bookings;
create policy "skin shop admin reads bookings"
on public.skin_shop_bookings for select to authenticated
using (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()));

-- Prevent direct client-side status edits; the RPC below performs acceptance atomically.
drop policy if exists "skin shop admin updates bookings" on public.skin_shop_bookings;
create policy "skin shop admin updates bookings"
on public.skin_shop_bookings for update to authenticated
using (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()))
with check (exists (select 1 from public.skin_shop_admins a where a.user_id = auth.uid()));

create or replace function public.skin_shop_review_booking(p_booking_id uuid, p_decision text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.skin_shop_bookings%rowtype;
begin
  if auth.uid() is null or not exists (
    select 1 from public.skin_shop_admins a where a.user_id = auth.uid()
  ) then
    raise exception 'Not authorized';
  end if;
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected';
  end if;

  select * into b from public.skin_shop_bookings
  where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status <> 'pending' then raise exception 'Booking is no longer pending'; end if;

  if p_decision = 'accepted' then
    update public.skin_shop_products
      set stock = stock - 1,
          active = (stock - 1) > 0
      where id = b.product_id and active = true and stock > 0;
    if not found then raise exception 'Out of stock'; end if;
  end if;

  update public.skin_shop_bookings
    set status = p_decision, reviewed_at = now()
    where id = p_booking_id;
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

revoke all on function public.skin_shop_review_booking(uuid,text) from public;
grant execute on function public.skin_shop_review_booking(uuid,text) to authenticated;
