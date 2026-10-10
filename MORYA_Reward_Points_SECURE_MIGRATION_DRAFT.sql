-- MORYA AGENCY REWARD POINTS — SECURITY-FIRST MIGRATION DRAFT
-- Draft only: review and test in a Supabase staging project before production.
-- Additive only: does not delete or rewrite existing orders, order_items, or products.
-- Earns 5% on ALL product categories when order status becomes Delivered.
-- Customers can read only their own ledger based on the verified Supabase Auth phone.
-- Admin access policy is intentionally not guessed; configure it after confirming admin auth.

begin;

create table if not exists public.reward_points_ledger (
  id uuid primary key default gen_random_uuid(),
  customer_mobile text not null,
  customer_name text,
  order_id uuid references public.orders(id) on delete restrict,
  entry_type text not null check (entry_type in ('earned','redeemed','reversal','adjustment')),
  points integer not null check (points <> 0),
  amount_inr numeric(12,2) not null default 0,
  note text,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists reward_points_ledger_mobile_created_idx
  on public.reward_points_ledger (customer_mobile, created_at desc);
create index if not exists reward_points_ledger_order_idx
  on public.reward_points_ledger (order_id);

alter table public.reward_points_ledger enable row level security;

drop policy if exists "Customers read their own reward ledger" on public.reward_points_ledger;
create policy "Customers read their own reward ledger"
on public.reward_points_ledger for select to authenticated
using (customer_mobile = right(regexp_replace(coalesce(auth.jwt() ->> 'phone',''), '[^0-9]', '', 'g'), 10));

create or replace view public.reward_points_balances
with (security_invoker = true) as
select customer_mobile, max(customer_name) as customer_name,
       coalesce(sum(points),0)::bigint as balance_points,
       coalesce(sum(points) filter (where entry_type='earned'),0)::bigint as earned_points,
       coalesce(-sum(points) filter (where entry_type='redeemed'),0)::bigint as redeemed_points,
       max(created_at) as last_activity_at
from public.reward_points_ledger group by customer_mobile;

create or replace function public.morya_apply_order_rewards()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  normalized_mobile text;
  eligible_amount numeric(12,2) := 0;
  earned integer := 0;
  prior_earned integer := 0;
  available integer := 0;
  already_reversed boolean := false;
  reversal integer := 0;
begin
  if new.status is not distinct from old.status then return new; end if;
  normalized_mobile := right(regexp_replace(coalesce(new.customer_mobile,''), '[^0-9]', '', 'g'), 10);
  if normalized_mobile = '' then return new; end if;

  if lower(coalesce(new.status,''))='delivered' and lower(coalesce(old.status,''))<>'delivered' then
    select coalesce(sum(coalesce(oi.unit_price,oi.price)*oi.quantity),0) into eligible_amount
    from public.order_items oi where oi.order_id=new.id;
    earned := floor(greatest(eligible_amount,0)*0.05)::integer;
    if earned>0 then
      insert into public.reward_points_ledger
        (customer_mobile,customer_name,order_id,entry_type,points,amount_inr,note,idempotency_key)
      values
        (normalized_mobile,new.customer_name,new.id,'earned',earned,eligible_amount,
         '5% reward on all product categories for delivered order','earned:'||new.id::text)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;

  if lower(coalesce(new.status,'')) in ('cancelled','canceled','returned')
     and lower(coalesce(old.status,''))='delivered' then
    select coalesce(sum(points),0)::integer into prior_earned
    from public.reward_points_ledger where order_id=new.id and entry_type='earned';
    select exists(select 1 from public.reward_points_ledger where idempotency_key='reversal:'||new.id::text)
    into already_reversed;
    if prior_earned>0 and not already_reversed then
      select coalesce(sum(points),0)::integer into available
      from public.reward_points_ledger where customer_mobile=normalized_mobile;
      reversal := least(prior_earned,greatest(available,0));
      if reversal>0 then
        insert into public.reward_points_ledger
          (customer_mobile,customer_name,order_id,entry_type,points,amount_inr,note,idempotency_key)
        values (normalized_mobile,new.customer_name,new.id,'reversal',-reversal,0,
          'Reward reversal on full cancellation/return; limited to available balance','reversal:'||new.id::text)
        on conflict (idempotency_key) do nothing;
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists morya_order_reward_status_trigger on public.orders;
create trigger morya_order_reward_status_trigger
after update of status on public.orders for each row execute function public.morya_apply_order_rewards();

-- p_request_id must be generated once per checkout attempt and reused for retries.
create or replace function public.morya_redeem_reward_points(p_points integer, p_request_id uuid)
returns table(success boolean, balance_points bigint, message text)
language plpgsql security definer set search_path = public
as $$
declare
  normalized_mobile text;
  current_balance bigint;
  existing_points integer;
  existing_mobile text;
begin
  if auth.uid() is null then
    return query select false,0::bigint,'Please sign in first.'::text; return;
  end if;
  normalized_mobile := right(regexp_replace(coalesce(auth.jwt()->>'phone',''),'[^0-9]','','g'),10);
  if length(normalized_mobile)<>10 then
    return query select false,0::bigint,'Verified phone number is required.'::text; return;
  end if;
  if p_points is null or p_points<=0 or p_request_id is null then
    return query select false,0::bigint,'Valid points and request ID are required.'::text; return;
  end if;

  perform pg_advisory_xact_lock(hashtext(normalized_mobile));
  select points, customer_mobile into existing_points, existing_mobile
    from public.reward_points_ledger
    where idempotency_key='redeemed:'||p_request_id::text;
  if found then
    select coalesce(sum(points),0)::bigint into current_balance
      from public.reward_points_ledger where customer_mobile=normalized_mobile;
    if existing_mobile is distinct from normalized_mobile
       or existing_points is distinct from -p_points then
      return query select false,current_balance,
        'Request ID was already used with different checkout details.'::text;
      return;
    end if;
    return query select true,current_balance,'This redemption request was already processed.'::text; return;
  end if;

  select coalesce(sum(points),0)::bigint into current_balance
    from public.reward_points_ledger where customer_mobile=normalized_mobile;
  if current_balance<p_points then
    return query select false,current_balance,'Insufficient reward balance.'::text; return;
  end if;

  insert into public.reward_points_ledger
    (customer_mobile,entry_type,points,amount_inr,note,idempotency_key)
  values (normalized_mobile,'redeemed',-p_points,p_points,'Customer checkout redemption','redeemed:'||p_request_id::text);

  select coalesce(sum(points),0)::bigint into current_balance
    from public.reward_points_ledger where customer_mobile=normalized_mobile;
  return query select true,current_balance,'Points redeemed.'::text;
end;
$$;

revoke all on function public.morya_redeem_reward_points(integer,uuid) from public,anon;
grant execute on function public.morya_redeem_reward_points(integer,uuid) to authenticated;
revoke insert,update,delete on public.reward_points_ledger from anon,authenticated;
grant select on public.reward_points_ledger to authenticated;
grant select on public.reward_points_balances to authenticated;

commit;

-- NOT READY FOR PRODUCTION until:
-- 1. Tested on staging and verified against actual order_items prices/status values.
-- 2. Admin-only read policy is added after confirming admin auth role (not guessed here).
-- 3. Checkout UI calls the redemption RPC with one stable UUID per attempt and only discounts after success.
-- 4. Partial returns are NOT implemented. Full cancellation/return after Delivered only reverses points still available; if points were already spent, the unreversed remainder needs a debt/offset design before production.
-- 5. Existing reward triggers/functions are checked to prevent duplicate rewards.
-- 6. Redemption is not transactionally coupled to order + order_items creation; do not enable checkout redemption until an atomic checkout RPC is implemented.
