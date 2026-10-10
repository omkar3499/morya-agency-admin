-- MORYA AGENCY REWARD POINTS — DRAFT MIGRATION
-- Review on a staging project before running in production.
-- Additive only: does not delete or rewrite existing order/product/customer rows.
-- Earns 5% on eligible categories only when an order transitions to Delivered.
-- This draft intentionally does NOT enable checkout redemption yet.

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

create or replace view public.reward_points_balances as
select
  customer_mobile,
  max(customer_name) as customer_name,
  coalesce(sum(points), 0)::bigint as balance_points,
  coalesce(sum(points) filter (where entry_type = 'earned'), 0)::bigint as earned_points,
  coalesce(-sum(points) filter (where entry_type = 'redeemed'), 0)::bigint as redeemed_points,
  max(created_at) as last_activity_at
from public.reward_points_ledger
group by customer_mobile;

create or replace function public.morya_apply_order_rewards()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  eligible_amount numeric(12,2) := 0;
  earned integer := 0;
  prior_earned integer := 0;
  available integer := 0;
  reversal integer := 0;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if lower(coalesce(new.status,'')) = 'delivered'
     and lower(coalesce(old.status,'')) <> 'delivered' then
    select coalesce(sum(oi.price * oi.quantity),0)
      into eligible_amount
    from public.order_items oi
    join public.products p on p.id = oi.product_id
    where oi.order_id = new.id
      and lower(coalesce(p.category,'')) in
        ('mobile_accessories','mobile_parts','mobile_cover','mobile_back_skin');

    earned := floor(greatest(eligible_amount,0) * 0.05)::integer;

    if earned > 0 then
      insert into public.reward_points_ledger
        (customer_mobile, customer_name, order_id, entry_type, points, amount_inr, note, idempotency_key)
      values
        (regexp_replace(coalesce(new.customer_mobile,''),'[^0-9]','','g'),
         new.customer_name, new.id, 'earned', earned, eligible_amount,
         '5% eligible category reward on delivered order', 'earned:'||new.id::text)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;

  if lower(coalesce(new.status,'')) in ('cancelled','canceled','returned')
     and lower(coalesce(old.status,'')) = 'delivered' then
    select coalesce(sum(points),0)::integer into prior_earned
      from public.reward_points_ledger
      where order_id = new.id and entry_type = 'earned';

    select coalesce(sum(points),0)::integer into available
      from public.reward_points_ledger
      where customer_mobile = regexp_replace(coalesce(new.customer_mobile,''),'[^0-9]','','g');

    reversal := least(prior_earned, greatest(available,0));
    if reversal > 0 then
      insert into public.reward_points_ledger
        (customer_mobile, customer_name, order_id, entry_type, points, amount_inr, note, idempotency_key)
      values
        (regexp_replace(coalesce(new.customer_mobile,''),'[^0-9]','','g'),
         new.customer_name, new.id, 'reversal', -reversal, 0,
         'Reward reversal on cancelled/returned delivered order; limited to available balance',
         'reversal:'||new.id::text)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists morya_order_reward_status_trigger on public.orders;
create trigger morya_order_reward_status_trigger
after update of status on public.orders
for each row execute function public.morya_apply_order_rewards();

commit;

-- SECURITY CHECKLIST BEFORE PRODUCTION:
-- 1. Enable RLS on reward_points_ledger and grant SELECT only through a verified customer identity/admin role.
-- 2. Do not grant anon/authenticated direct INSERT/UPDATE/DELETE on ledger.
-- 3. Customer identity is currently keyed by normalized mobile; do not expose other customers' rows.
-- 4. Checkout redemption RPC and partial-return item-level reversals are NOT implemented in this draft.
-- 5. Test in staging first; verify products.category values and orders.status values before production.
