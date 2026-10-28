-- MORYA AGENCY Mobile Skin Shop: safe customer-side policies
-- These policies only affect the NEW skin_shop_* tables.
-- Admin write/accept actions remain disabled until the admin Auth UID is verified.

alter table public.skin_shop_bookings
  add column if not exists quantity integer not null default 1
  check (quantity = 1);

drop policy if exists "skin shop customers view in-stock designs" on public.skin_shop_products;
create policy "skin shop customers view in-stock designs"
on public.skin_shop_products
for select to anon, authenticated
using (active = true and stock > 0);

drop policy if exists "skin shop customers create pending booking" on public.skin_shop_bookings;
create policy "skin shop customers create pending booking"
on public.skin_shop_bookings
for insert to anon, authenticated
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

-- No public UPDATE/DELETE policies are created.
-- Do not expose service_role keys in browser code.
-- Next step: verify the owner's Supabase Auth UID, then add admin-only policies
-- and an atomic server-side accept-booking function to decrement stock exactly once.
