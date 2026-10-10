-- MORYA AGENCY ATOMIC CHECKOUT + REWARD REDEMPTION — STAGING DRAFT
-- Additive migration draft only. Do NOT run against production before staging tests.
-- Depends on public.products, orders, order_items, reward_points_ledger and the
-- morya_apply_order_rewards() trigger from MORYA_Reward_Points_SECURE_MIGRATION_DRAFT.sql.
-- Prices are read from products.price. Items without real catalog UUIDs are rejected.
-- p_reward_points means points to redeem; ₹1 = 1 point.
-- Existing order_items stock trigger must reject insufficient stock and roll back safely.

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
returns table(success boolean, order_id uuid, subtotal numeric, reward_used integer,
              delivery_fee numeric, total_amount numeric, message text)
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
  if length(v_verified_mobile)<>10 or v_mobile<>v_verified_mobile then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Checkout mobile must match verified login phone.'::text;
    return;
  end if;
  if coalesce(trim(p_customer_name),'')='' or coalesce(trim(p_customer_address),'')='' then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Name and full address are required.'::text;
    return;
  end if;
  if p_delivery not in ('pickup','home') then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Invalid delivery option.'::text;
    return;
  end if;
  if v_points<0 then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Reward points cannot be negative.'::text;
    return;
  end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then
    return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Cart is empty.'::text;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext(v_mobile));
  perform pg_advisory_xact_lock(hashtext(p_request_id::text));

  -- Idempotent retry: return existing order; never redeem a second time.
  select * into v_existing from public.orders where checkout_request_id=p_request_id;
  if found then
    return query select true,v_existing.id,
      greatest(coalesce(v_existing.total_amount,0) - case when p_delivery='home' then 80 else 0 end,0)::numeric,
      v_points,
      case when p_delivery='home' then 80::numeric else 0::numeric end,
      coalesce(v_existing.total_amount,0)::numeric,
      'This checkout request was already processed.'::text;
    return;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := (v_item->>'quantity')::integer;
    exception when others then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Cart item has an invalid product ID or quantity.'::text;
      return;
    end;
    if v_quantity is null or v_quantity<1 or v_quantity>100 then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Invalid item quantity.'::text;
      return;
    end if;
    select p.name,p.price into v_product_name,v_unit_price
      from public.products p where p.id=v_product_id for share;
    if not found then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Product not found in catalog.'::text;
      return;
    end if;
    if v_unit_price is null or v_unit_price<=0 then
      return query select false,null::uuid,0::numeric,0,0::numeric,0::numeric,'Product price must be greater than zero.'::text;
      return;
    end if;
    v_subtotal := v_subtotal + v_unit_price*v_quantity;
  end loop;

  if v_points>floor(v_subtotal)::integer then
    return query select false,null::uuid,v_subtotal,0,0::numeric,v_subtotal,'Redeemed points cannot exceed item subtotal.'::text;
    return;
  end if;

  select coalesce(sum(points),0)::bigint into v_balance
    from public.reward_points_ledger where customer_mobile=v_mobile;
  if v_points>v_balance then
    return query select false,null::uuid,v_subtotal,0,0::numeric,v_subtotal,'Insufficient reward points.'::text;
    return;
  end if;

  v_delivery_fee := case when p_delivery='home' then 80 else 0 end;
  v_total := greatest(v_subtotal-v_points,0)+v_delivery_fee;

  insert into public.orders
    (checkout_request_id,customer_name,customer_mobile,customer_address,total_amount,status,
     payment_method,payment_status,instructions)
  values
    (p_request_id,left(trim(p_customer_name),200),v_mobile,left(trim(p_customer_address),1000),
     v_total,'Order Received','Cash on Delivery','pending','Delivery: '||p_delivery)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    v_model_or_size := left(coalesce(v_item->>'model_or_size',''),250);
    select p.name,p.price into v_product_name,v_unit_price from public.products p where p.id=v_product_id;
    insert into public.order_items(order_id,product_id,product_name,model_or_size,quantity,price,unit_price)
    values(v_order_id,v_product_id,left(v_product_name,250),v_model_or_size,v_quantity,v_unit_price,v_unit_price);
  end loop;

  if v_points>0 then
    insert into public.reward_points_ledger
      (customer_mobile,customer_name,order_id,entry_type,points,amount_inr,note,idempotency_key)
    values
      (v_mobile,left(trim(p_customer_name),200),v_order_id,'redeemed',-v_points,v_points,
       'Reward points redeemed during atomic checkout','checkout-redeem:'||p_request_id::text);
  end if;

  return query select true,v_order_id,v_subtotal,v_points,v_delivery_fee,v_total,'Order and reward redemption saved atomically.'::text;
exception when unique_violation then
  -- Unique request ID prevents duplicate orders if two retries race.
  select * into v_existing from public.orders where checkout_request_id=p_request_id;
  if found then
    return query select true,v_existing.id,0::numeric,v_points,0::numeric,
      coalesce(v_existing.total_amount,0)::numeric,'This checkout request was already processed.'::text;
    return;
  end if;
  raise;
end;
$$;

revoke all on function public.morya_checkout_with_rewards(uuid,text,text,text,text,jsonb,integer) from public,anon;
grant execute on function public.morya_checkout_with_rewards(uuid,text,text,text,text,jsonb,integer) to authenticated;

commit;

-- PRE-PRODUCTION GATES:
-- 1. Confirm orders column names/required fields and reward ledger migration are applied in staging.
-- 2. Verify all customer cart product IDs map to public.products.id, including custom printing and handsets.
-- 3. Test stock trigger under concurrent purchases; transaction must reject insufficient stock.
-- 4. Verify idempotent retry response includes the originally redeemed points and correct subtotal/fee.
-- 5. Test redemption=0, exact balance, insufficient balance, and concurrent same-customer checkouts.
-- 6. Integrate this RPC in Customer HTML only after staging success; do not enable direct browser order inserts.
-- 7. This RPC does not implement partial refund/return workflow or admin refund authorization.
