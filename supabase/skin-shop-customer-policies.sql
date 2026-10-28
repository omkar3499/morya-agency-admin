-- MORYA AGENCY: Mobile Skin integration policies
-- Run only after confirming the correct Admin Auth user UUID.
-- Public customers can view in-stock active designs and create pending bookings.
-- Admin write policies are intentionally omitted until the owner's Auth UID is verified.

drop policy if exists "skin shop customers view in-stock designs" on public.skin_shop_products;
create policy "skin shop customers view in-stock designs"
on public.skin_shop_products for select
to anon, authenticated
using (active = true and stock > 0);

drop policy if exists "skin shop customers create pending booking" on public.skin_shop_bookings;
create policy "skin shop customers create pending booking"
on public.skin_shop_bookings for insert
to anon, authenticated
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

-- Do NOT add public UPDATE policies. Admin actions need a verified Auth UID
-- and a secure policy/RPC that decrements stock atomically on acceptance.
