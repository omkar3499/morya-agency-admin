-- MORYA AGENCY REWARD POINTS: additive starter migration
-- Creates new reward ledger objects only; does not delete or rewrite existing orders/products.
-- Review before running in Supabase SQL Editor. Back up the project first.

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

commit;

-- IMPORTANT: this is a schema starter only, NOT a complete live rewards system.
-- Before live use, configure RLS/server-side authorization, order-completion 5% credit,
-- validated checkout redemption, idempotency, and cancellation/partial-return reversals.
-- Do not enable redemption until these are implemented and tested.
