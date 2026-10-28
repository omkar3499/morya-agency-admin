-- MORYA AGENCY | MOBILE SKIN SHOP
-- SAFE, SEPARATE SCHEMA: does not modify existing products/orders tables.
-- Review before running in Supabase SQL Editor.

create table if not exists public.skin_shop_products (
  id uuid primary key default gen_random_uuid(),
  design_name text not null,
  image_url text,
  price numeric(10,2) not null default 149 check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.skin_shop_bookings (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.skin_shop_products(id),
  customer_name text not null,
  customer_phone text not null,
  quantity integer not null default 1 check (quantity = 1),
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected','cancelled')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

alter table public.skin_shop_products enable row level security;
alter table public.skin_shop_bookings enable row level security;

-- Customers can only see active designs that are in stock.
drop policy if exists "skin shop customers view in-stock designs" on public.skin_shop_products;
create policy "skin shop customers view in-stock designs"
on public.skin_shop_products for select
to anon, authenticated
using (active = true and stock > 0);

-- Customers may submit a pending booking only. They cannot accept bookings
-- or change stock/status through this policy.
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

-- Intentionally no public UPDATE/DELETE/booking-read policy.
-- Owner/admin operations must use a properly authenticated server-side flow.
-- Never put the Supabase service_role key in HTML, JavaScript, or an APK.
