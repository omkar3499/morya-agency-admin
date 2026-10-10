-- MORYA AGENCY PARTIAL RETURN REWARD REVERSAL — STAGING DRAFT ONLY
-- Do not run in production until reviewed and tested with the full rewards migration.
-- Admin-only RPC: records a proportional reversal for a partial return.
-- Points already spent are not made spendable again: the net ledger can be negative,
-- while reward_points_balances should clamp spendable balance to zero and show reversal_debt_points.
-- This function does not change order status, inventory, refunds, or payment records.
-- Request table persists zero-point returns too, preventing request-ID reuse and retry drift.

begin;

create table if not exists public.reward_return_requests (
  request_id uuid primary key,
  order_id uuid not null references public.orders(id) on delete restrict,
  returned_amount_inr numeric(12,2) not null check (returned_amount_inr > 0),
  reversed_points integer not null default 0 check (reversed_points >= 0),
  created_at timestamptz not null default now()
);
alter table public.reward_return_requests enable row level security;
revoke all on public.reward_return_requests from public, anon, authenticated;

create or replace function public.morya_record_partial_reward_return(
  p_order_id uuid,
  p_returned_amount_inr numeric(12,2),
  p_request_id uuid
)
returns table(success boolean, reversed_points integer, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
  v_mobile text;
  v_name text;
  v_earned_points integer;
  v_earned_amount numeric(12,2);
  v_prior_return_amount numeric(12,2);
  v_new_total_return numeric(12,2);
  v_target_points integer;
  v_prior_reversed_points integer;
  v_delta integer;
  v_existing_points integer;
  v_existing_order_id uuid;
  v_existing_amount numeric(12,2);
begin
  v_email := lower(coalesce(auth.jwt()->>'email',''));
  if auth.uid() is null or v_email <> 'ozagade8@gmail.com' then
    return query select false, 0, 'Admin account required.'::text;
    return;
  end if;

  if p_order_id is null or p_request_id is null
     or p_returned_amount_inr is null or p_returned_amount_inr <= 0 then
    return query select false, 0, 'Order, request ID and a positive return amount are required.'::text;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_order_id::text));

  select points, customer_mobile, customer_name, amount_inr
    into v_earned_points, v_mobile, v_name, v_earned_amount
  from public.reward_points_ledger
  where order_id = p_order_id and entry_type = 'earned'
  order by created_at asc
  limit 1;

  if not found or v_earned_points <= 0 or coalesce(v_earned_amount,0) <= 0 then
    return query select false, 0, 'No eligible earned rewards found for this order.'::text;
    return;
  end if;

  select order_id, returned_amount_inr, reversed_points
    into v_existing_order_id, v_existing_amount, v_existing_points
  from public.reward_return_requests
  where request_id = p_request_id;

  if found then
    if v_existing_order_id <> p_order_id or v_existing_amount <> p_returned_amount_inr then
      return query select false, 0, 'Request ID was already used with different return details.'::text;
    else
      return query select true, v_existing_points, 'This return request was already processed.'::text;
    end if;
    return;
  end if;

  select coalesce(sum(returned_amount_inr),0)::numeric(12,2)
    into v_prior_return_amount
  from public.reward_return_requests
  where order_id = p_order_id;

  select coalesce(-sum(points),0)::integer
    into v_prior_reversed_points
  from public.reward_points_ledger
  where order_id = p_order_id and entry_type = 'reversal'
    and idempotency_key like 'partial-return:%';

  if v_prior_return_amount + p_returned_amount_inr > v_earned_amount then
    return query select false, 0, 'Cumulative returned amount cannot exceed the reward-eligible order amount.'::text;
    return;
  end if;
  v_new_total_return := v_prior_return_amount + p_returned_amount_inr;
  v_target_points := floor(v_earned_points * v_new_total_return / v_earned_amount)::integer;
  v_delta := greatest(v_target_points - v_prior_reversed_points, 0);

  insert into public.reward_return_requests(request_id, order_id, returned_amount_inr, reversed_points)
  values (p_request_id, p_order_id, p_returned_amount_inr, v_delta);

  if v_delta = 0 then
    return query select true, 0, 'Return recorded; no additional whole reward point due.'::text;
    return;
  end if;

  insert into public.reward_points_ledger
    (customer_mobile, customer_name, order_id, entry_type, points, amount_inr, note, idempotency_key)
  values
    (v_mobile, v_name, p_order_id, 'reversal', -v_delta, p_returned_amount_inr,
     'Proportional reward reversal for partial return',
     'partial-return:' || p_request_id::text);

  return query select true, v_delta, 'Partial return reward adjustment recorded.'::text;
end;
$$;

revoke all on function public.morya_record_partial_reward_return(uuid,numeric,uuid) from public, anon, authenticated;
grant execute on function public.morya_record_partial_reward_return(uuid,numeric,uuid) to authenticated;

commit;

-- REQUIRED REVIEW BEFORE USE:
-- 1. Confirm admin JWT email and ledger schema/constraints.
-- 2. Request IDs and zero-point returns are persisted in reward_return_requests.
-- 3. Test repeated request IDs, cumulative partial returns, full returns, and spent points in staging.
-- 4. Integrate return amount with actual refund workflow; this RPC only adjusts rewards.
