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
