# 800+ Pharmacy POS (Supabase version)

Files: index.html (the POS), sw.js (offline page loading), schema.sql (database), supabase/functions/create-user/index.ts (admin account creation).
The Project URL and publishable key are already set near the end of index.html (SB_URL, SB_KEY). Never put the secret/service_role key or the database password in any of these files.

## Setup (in this order)
1. Supabase > Authentication > Sign In / Providers: turn OFF "Confirm email" and turn OFF "Allow new users to sign up".
2. Authentication > Users > Add user: admin@800plus.pos + a strong password, tick auto-confirm (skip if already done).
3. SQL Editor > New query > paste all of schema.sql > Run. The last result row should show products = 1 and admins = 1.
   If admins = 0, the admin user did not exist yet: create it (step 2), then run only the last "insert into public.profiles" block again.
4. Edge Functions > Deploy a new function > name it exactly: create-user > paste supabase/functions/create-user/index.ts > Deploy. (Needed for the Users tab.)
5. GitHub: create the repository, upload index.html, sw.js, schema.sql, README.md and the supabase folder.
   Settings > Pages > Deploy from branch (main, root). Note: GitHub Pages from a PRIVATE repository needs a paid GitHub plan; on a free plan use a public repo (no secrets are in it) or host the same files on Netlify / Cloudflare Pages.
6. Open the Pages address (must be https), log in as admin with username "admin", and create cashier accounts in the Users tab.

## Test before real use (two browsers or two computers)
1. Admin: add a product with stock 5. Check it appears on the cashier computer within a few seconds.
2. Both cashiers sell the last 3 units at the same moment: one must be refused with "Not enough stock", stock must end at 2 or 0, never negative.
3. Sell one item, check Reports shows exactly one sale and stock dropped by exactly the quantity sold.
4. Cashier computer: turn Wi-Fi off, sell items (an OFFLINE badge and "waiting to sync" show). Reload the page: it must still open and the sale still be waiting. Turn Wi-Fi on: it must sync by itself, once.
5. Offline oversell: with 1 unit left, sell 2 offline on a computer, reconnect. Admin dashboard must show a red "Oversold sales need review" box; stock shows negative until Stock in corrects it.
6. As cashier, try Inventory/Users: they must not exist. In the browser console, a cashier updating products directly must fail (RLS).

## Offline limits
- Open the app online once first (and log in); after that it opens and sells offline. A fresh login needs internet.
- Offline sales sit in this browser's storage. Clearing browser data, or switching browser/computer, before they sync loses them. A cashier cannot log out while sales are waiting.
- Offline stock numbers can be old; two offline computers can sell the same last item. It is recorded and flagged for the admin.
- Offline sales use the prices the computer last saw. Admin tasks (products, stock in, users, reports) need internet.
- Discount amounts are worked out in the cashier's browser, as before; review discounts in Reports.
