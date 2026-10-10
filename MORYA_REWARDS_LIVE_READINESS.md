# MORYA Agency Rewards — Live Readiness Checklist

Status: DRAFT / TEST BRANCH ONLY. Do not run this migration in production yet.

## What the current draft does
- Additive reward ledger and balance view; it does not delete existing orders/products.
- Earns 5% of order-item subtotal for all categories when order status transitions to Delivered.
- Customer read access is limited by the verified Supabase Auth phone number.
- Redemption request ID checks are hardened against reuse with different points/customer.

## Blocking items before live
1. Confirm actual Supabase schema and RLS for orders/order_items/products.
2. Implement a single atomic checkout RPC that inserts the order and all items together. Current customer page inserts order and items separately; item insert failure can leave an orphan order.
3. Implement checkout redemption inside that same atomic RPC. Do not discount locally or call redemption separately.
4. Design and test full/partial returns after some points have already been spent. The current draft must not be treated as a complete return-accounting system.
5. Configure a verified admin-only read path for customer-wise reports. Do not expose every customer's ledger to ordinary authenticated users.
6. Test duplicate Delivered updates, order retries, cancellation, return, concurrent redemption, and negative-balance prevention in a staging Supabase project.
7. Verify deployed GitHub Pages uses the reviewed files and test checkout on mobile.

## Live safety
- Do not replace the main branch or run SQL against production until the blocking items above pass.
- Customer checkout currently intentionally applies zero reward discount.
- The draft SQL is not active merely because it exists in GitHub.


## Diagnostics confirmed on 2026-10-10 (read-only queries)
- RLS is enabled on `orders`, `order_items`, and `products`; `reward_points_ledger` does not exist in the live schema yet.
- Existing policies include broad insert policies for `orders` and `order_items`; policy predicates shown for some insert policies have no `WITH CHECK` restriction. This must be reviewed before enabling customer checkout/rewards.
- Existing trigger `trg_decrease_product_stock` runs AFTER INSERT on `order_items`; preserve it and ensure checkout inserts each item exactly once.
- Current visible data has 7 orders: 1 Cancelled, 1 Delivered, 3 New, 2 Ready.
- Several existing orders have zero linked `order_items`. The Delivered ₹149 order has no linked items, so it must not be backfilled with reward points based on `orders.total_amount` alone.
- Product catalog currently shows 10 rows across `custom_printing`, `mobile_accessories`, and `mobiles`. Rewards should include all categories, but only the actual saved item subtotal should qualify.
- Only two distinct product IDs are present in current `order_items` rows. Some rows have `product_id` null; use the saved item name/price/quantity for audit, not product_id alone.

## Next implementation gate
Do not ask the user to run more diagnostic queries right now. Implement and review a staging-only atomic checkout path (order + items + optional redemption in one transaction), plus return/clawback accounting, before giving any production SQL. No live database writes have been made by these diagnostics.
