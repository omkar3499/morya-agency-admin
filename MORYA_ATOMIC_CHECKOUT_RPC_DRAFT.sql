-- MORYA AGENCY ATOMIC CHECKOUT RPC — REVIEW / STAGING DRAFT ONLY
-- Do NOT run in production yet.
-- This creates a server-side transaction for order + order_items.
-- Intentionally accepts ONLY product IDs that exist in public.products and prices from products.price.
-- Custom/local cart items without a real product UUID need a proper catalog/SKU mapping before this can be used.
-- Existing order_items stock trigger may decrement stock; test rollback and stock behavior in staging.

begin;

create or replace function public.morya_create_order_atomic(
  p_customer_name text,
  p_customer_mobile text,
  p_customer_address text,
  p_delivery text,
  p_items jsonb
)
returns table(success boolean, order_id uuid, total_amount numeric, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mobile text;
  v_verified_mobile text;
  v_item jsonb;
  v_product_id uuid;
  v_product_name text;
  v_model_or_size text;
  v_quantity integer;
  v_unit_price numeric(12,2);
  v_subtotal numeric(12,2) := 0;
  v_delivery_fee numeric(12,2) := 0;
  v_total numeric(12,2);
  v_order_id uuid;
  v_rows integer := 0;
begin
  if auth.uid() is null then
    return query select false, null::uuid, 0::numeric, 'Please sign in first.'::text;
    return;
  end if;

  v_verified_mobile := right(regexp_replace(coalesce(auth.jwt()->>'phone',''), '[^0-9]', '', 'g'), 10);
  v_mobile := right(regexp_replace(coalesce(p_customer_mobile,''), '[^0-9]', '', 'g'), 10);
  if length(v_verified_mobile) <> 10 or v_mobile <> v_verified_mobile then
    return query select false, null::uuid, 0::numeric, 'Checkout mobile must match the verified login phone.'::text;
    return;
  end if;

  if coalesce(trim(p_customer_name),'') = '' or coalesce(trim(p_customer_address),'') = '' then
    return query select false, null::uuid, 0::numeric, 'Name and full address are required.'::text;
    return;
  end if;

  if p_delivery not in ('pickup','home') then
    return query select false, null::uuid, 0::numeric, 'Invalid delivery option.'::text;
    return;
  end if;
  v_delivery_fee := case when p_delivery = 'home' then 80 else 0 end;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    return query select false, null::uuid, 0::numeric, 'Cart is empty.'::text;
    return;
  end if;

  -- Resolve every item and price from the database; never trust client-submitted prices.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
    exception when others then
      return query select false, null::uuid, 0::numeric,
        'A cart item has no valid catalog product ID. Map custom/local items to catalog products first.'::text;
      return;
    end;

    v_quantity := (v_item->>'quantity')::integer;
    if v_quantity is null or v_quantity < 1 or v_quantity > 100 then
      return query select false, null::uuid, 0::numeric, 'Invalid item quantity.'::text;
      return;
    end if;

    select p.name, p.price
      into v_product_name, v_unit_price
    from public.products p
    where p.id = v_product_id
    for share;

    if not found then
      return query select false, null::uuid, 0::numeric, 'A product is no longer available.'::text;
      return;
    end if;
    if v_unit_price is null or v_unit_price < 0 then
      return query select false, null::uuid, 0::numeric, 'Product price is invalid.'::text;
      return;
    end if;

    v_model_or_size := left(coalesce(v_item->>'model_or_size',''),250);
    v_subtotal := v_subtotal + (v_unit_price * v_quantity);
    v_rows := v_rows + 1;
  end loop;

  v_total := v_subtotal + v_delivery_fee;

  insert into public.orders
    (customer_name, customer_mobile, customer_address, total_amount, status,
     payment_method, payment_status, instructions)
  values
    (left(trim(p_customer_name),200), v_mobile, left(trim(p_customer_address),1000),
     v_total, 'Order Received', 'Cash on Delivery', 'pending',
     'Delivery: ' || p_delivery)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    v_model_or_size := left(coalesce(v_item->>'model_or_size',''),250);

    select p.name, p.price into v_product_name, v_unit_price
    from public.products p where p.id = v_product_id;

    insert into public.order_items
      (order_id, product_id, product_name, model_or_size, quantity, price, unit_price)
    values
      (v_order_id, v_product_id, left(v_product_name,250), v_model_or_size,
       v_quantity, v_unit_price, v_unit_price);
  end loop;

  return query select true, v_order_id, v_total, 'Order and items saved atomically.'::text;
  return;
exception when others then
  -- Any unhandled insert/trigger failure aborts the function transaction, rolling back order + items.
  raise;
end;
$$;

revoke all on function public.morya_create_order_atomic(text,text,text,text,jsonb) from public, anon;
grant execute on function public.morya_create_order_atomic(text,text,text,text,jsonb) to authenticated;

commit;

-- BEFORE production:
-- 1. Confirm actual columns, constraints, RLS, and orders required fields in staging.
-- 2. Verify products.price is the correct authoritative price and whether custom-print products have catalog UUIDs.
-- 3. Test existing trg_decrease_product_stock behavior, stock rollback, and insufficient stock concurrency.
-- 4. Add idempotency request ID so retries cannot create duplicate orders.
-- 5. Add reward redemption inside THIS transaction before enabling checkout redemption.
-- 6. Wire customer HTML only after successful staging tests. Do not run this file against live yet.
