-- MORYA REWARDS ACCOUNTING TEST PLAN + READ-ONLY DIAGNOSTICS
-- Draft only. This file does not modify any database data.
-- Run only the SELECT diagnostics in Supabase SQL Editor. Do NOT run a reward migration yet.

-- 1) Check order status spellings and counts.
SELECT lower(trim(coalesce(status,''))) AS status_normalized,
       count(*) AS order_count
FROM public.orders
GROUP BY 1
ORDER BY 1;

-- 2) Check Delivered orders and whether they have saved order_items.
SELECT o.id, o.customer_name, o.customer_mobile, o.status,
       o.total_amount,
       count(oi.order_id) AS item_rows,
       coalesce(sum(coalesce(oi.unit_price,oi.price) * oi.quantity),0) AS item_subtotal
FROM public.orders o
LEFT JOIN public.order_items oi ON oi.order_id = o.id
WHERE lower(trim(coalesce(o.status,''))) = 'delivered'
GROUP BY o.id, o.customer_name, o.customer_mobile, o.status, o.total_amount
ORDER BY o.created_at DESC;

-- 3) Check order items with missing/zero price or invalid quantity.
SELECT order_id, product_name, quantity, price, unit_price
FROM public.order_items
WHERE quantity IS NULL OR quantity <= 0
   OR coalesce(unit_price,price) IS NULL
   OR coalesce(unit_price,price) < 0;

-- 4) Check products and IDs required by atomic checkout.
SELECT id, name, category, price, stock
FROM public.products
ORDER BY category, name;

-- 5) Check existing triggers on orders and order_items to avoid double rewards
-- or unexpected stock changes. Read-only catalog query.
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       t.tgname AS trigger_name,
       pg_get_triggerdef(t.oid) AS trigger_definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname = 'public'
  AND c.relname IN ('orders','order_items')
ORDER BY c.relname, t.tgname;

-- 6) Check required columns and nullability for order + item inserts.
SELECT table_name, column_name, is_nullable, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('orders','order_items','products')
ORDER BY table_name, ordinal_position;

-- No writes, no DDL, no policies, no triggers, no point balances changed by this file.
