-- MORYA AGENCY ATOMIC CHECKOUT + REWARD REDEMPTION — REVIEW DRAFT
-- Draft only. Do NOT run in production before staging tests and schema/trigger review.
-- Uses the existing order_items stock trigger; this function does not manually decrement stock.
-- IMPORTANT: confirm the existing stock trigger rejects insufficient stock and rolls back safely.
-- Requires reward_points_ledger and the reward status trigger from the secure migration draft.

begin;

alter table public.orders
  add column if not exists checkout_request_id uuid;

create unique index if not exists orders_checkout_request_id_uidx
  on public.orders(checkout_request_id)
  where checkout_request_id is not null;

create or replace function public.morya_checkout_with_rewards(
  p_request_id uuid,
  p_customer_name text,
  p_customer_mobile text,
  p_customer_address text,
  p_delivery text,
  p_items jsonb,
  p_reward_points integer default 0
)
returns table(
  success boolean, order_id uuid, subtotal numeric, reward_used integer,
  delivery_fee numeric, total_amount numeric, message text
)
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
  v_stock integer;
  v_total_quantity integer;
  v_subtotal numeric(12,2) := 0;
  v_delivery_fee numeric(12,2) := 0;
  v_total numeric(12,2);
  v_order_id uuid;
  v_balance bigint;
  v_points integer := coalesce(p_reward_points,0);
  v_existing public.orders%rowtype;
begin
  if auth.uid() is null then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Please sign in first.'::text;
    return;
  end if;
  if p_request_id is null then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Checkout request ID is required.'::text;
    return;
  end if;

  v_verified_mobile := right(regexp_replace(coalesce(auth.jwt()->>'phone',''),'[^0-9]','','g'),10);
  v_mobile := right(regexp_replace(coalesce(p_customer_mobile,''),'[^0-9]','','g'),10);
  if length(v_verified_mobile) <> 10 or v_mobile <> v_verified_mobile then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Checkout mobile must match verified login phone.'::text;
    return;
  end if;
  if coalesce(trim(p_customer_name),'') = '' or coalesce(trim(p_customer_address),'') = '' then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Name and full address are required.'::text;
    return;
  end if;
  if p_delivery not in ('pickup','home') then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Invalid delivery option.'::text;
    return;
  end if;
  if v_points < 0 then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Reward points cannot be negative.'::text;
    return;
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Cart is empty.'::text;
    return;
  end if;

  -- Validate JSON types/values before UUID and integer casts.
  if exists (
    select 1
    from jsonb_array_elements(p_items) e(value)
    where coalesce(e.value->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       or coalesce(e.value->>'quantity','') !~ '^[0-9]+$'
  ) then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Cart item has an invalid product ID or quantity.'::text;
    return;
  end if;

  -- Serialize checkout attempts for this customer and request ID.
  perform pg_advisory_xact_lock(hashtext(v_mobile));
  perform pg_advisory_xact_lock(hashtext(p_request_id::text));

  -- Idempotent retry: return the original order, without a second redemption.
  select * into v_existing from public.orders where checkout_request_id = p_request_id;
  if found then
    select coalesce(sum(coalesce(oi.unit_price,oi.price)*oi.quantity),0)::numeric(12,2)
      into v_subtotal
    from public.order_items oi where oi.order_id = v_existing.id;
    select coalesce(-sum(l.points),0)::integer into v_points
    from public.reward_points_ledger l
    where l.idempotency_key = 'checkout-redeem:'||p_request_id::text;
    v_delivery_fee := case when coalesce(v_existing.instructions,'') like '%Delivery: home%' then 80 else 0 end;
    return query select true,v_existing.id,v_subtotal,coalesce(v_points,0),
      v_delivery_fee,coalesce(v_existing.total_amount,0)::numeric,
      'This checkout request was already processed.'::text;
    return;
  end if;

  -- Lock each catalog product before checking current price and stock.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    if v_quantity < 1 or v_quantity > 100 then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Invalid item quantity.'::text;
      return;
    end if;

    select p.name,p.price,p.stock into v_product_name,v_unit_price,v_stock
    from public.products p where p.id = v_product_id for update;
    if not found then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Product not found in catalog.'::text;
      return;
    end if;
    if v_unit_price is null or v_unit_price <= 0 then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Product price must be greater than zero.'::text;
      return;
    end if;

    select coalesce(sum((e.value->>'quantity')::integer),0)::integer
      into v_total_quantity
    from jsonb_array_elements(p_items) e(value)
    where (e.value->>'product_id')::uuid = v_product_id;
    if v_stock is not null and v_stock < v_total_quantity then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,('Insufficient stock for '||v_product_name||'.')::text;
      return;
    end if;
    v_subtotal := v_subtotal + v_unit_price * v_quantity;
  end loop;

  if v_points > floor(v_subtotal)::integer then
    return query select false,null::uuid,v_subtotal,0,0::numeric,v_subtotal,'Redeemed points cannot exceed item subtotal.'::text;
    return;
  end if;

  select coalesce(sum(points),0)::bigint into v_balance
  from public.reward_points_ledger where customer_mobile = v_mobile;
  if v_points > v_balance then
    return query select false,null::uuid,v_subtotal,0,0::numeric,v_subtotal,'Insufficient reward points.'::text;
    return;
  end if;

  v_delivery_fee := case when p_delivery = 'home' then 80 else 0 end;
  v_total := greatest(v_subtotal-v_points,0) + v_delivery_fee;

  insert into public.orders
    (checkout_request_id,customer_name,customer_mobile,customer_address,total_amount,status,
     payment_method,payment_status,instructions)
  values
    (p_request_id,left(trim(p_customer_name),200),v_mobile,left(trim(p_customer_address),1000),
     v_total,'New','Cash on Delivery','pending','Delivery: '||p_delivery)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    v_model_or_size := left(coalesce(v_item->>'model_or_size',''),250);
    select p.name,p.price into v_product_name,v_unit_price
    from public.products p where p.id = v_product_id;
    insert into public.order_items
      (order_id,product_id,product_name,model_or_size,quantity,price,unit_price)
    values
      (v_order_id,v_product_id,left(v_product_name,250),v_model_or_size,v_quantity,v_unit_price,v_unit_price);
  end loop;

  if v_points > 0 then
    insert into public.reward_points_ledger
      (customer_mobile,customer_name,order_id,entry_type,points,amount_inr,note,idempotency_key)
    values
      (v_mobile,left(trim(p_customer_name),200),v_order_id,'redeemed',-v_points,v_points,
       'Reward points redeemed during atomic checkout','checkout-redeem:'||p_request_id::text);
  end if;

  return query select true,v_order_id,v_subtotal,v_points,v_delivery_fee,v_total,
    'Order and reward redemption saved atomically.'::text;
exception when unique_violation then
  select * into v_existing from public.orders where checkout_request_id = p_request_id;
  if found then
    select coalesce(sum(coalesce(oi.unit_price,oi.price)*oi.quantity),0)::numeric(12,2)
      into v_subtotal from public.order_items oi where oi.order_id = v_existing.id;
    select coalesce(-sum(l.points),0)::integer into v_points
    from public.reward_points_ledger l
    where l.idempotency_key = 'checkout-redeem:'||p_request_id::text;
    v_delivery_fee := case when coalesce(v_existing.instructions,'') like '%Delivery: home%' then 80 else 0 end;
    return query select true,v_existing.id,v_subtotal,coalesce(v_points,0),
      v_delivery_fee,coalesce(v_existing.total_amount,0)::numeric,
      'This checkout request was already processed.'::text;
    return;
  end if;
  raise;
end;
$$;

revoke all on function public.morya_checkout_with_rewards(uuid,text,text,text,text,jsonb,integer) from public,anon;
grant execute on function public.morya_checkout_with_rewards(uuid,text,text,text,text,jsonb,integer) to authenticated;

commit;

-- REQUIRED STAGING CHECKS BEFORE PRODUCTION:
-- 1. Confirm all referenced columns and required order fields against the live schema.
-- 2. Inspect the existing order_items stock trigger. This RPC does NOT manually update stock;
--    confirm the trigger decrements once, rejects insufficient stock, and rolls back transactionally.
-- 3. Confirm customer cart product_id values are actual products.id UUIDs for every category.
-- 4. Test same request ID retries, duplicate cart rows, concurrent checkouts, zero/exact/insufficient points.
-- 5. Check the configured order status spelling and delivery fee policy with the Admin UI.
-- 6. Test reward earn trigger after Delivered transition and rollback behavior in staging.
-- 7. Do not enable checkout redemption until these tests pass. Partial returns are handled separately.
