# Trinetra

**Wholesale buying, clearly seen.**

Trinetra (Sanskrit: "three eyes", after the third eye of Shiva that sees everything) is a B2B wholesale marketplace where retailers like D-Mart or Metro buy in bulk from brands like Tata, Havells and Dabur. The name reflects what the platform gives each side: buyers see the exact price at every quantity, suppliers see what is selling, and the admin sees every rupee of credit and every unit of stock.

What makes it different from a normal shop:

- **Volume price slabs.** The more you buy, the lower the unit price (1–9 fans at ₹2,500, 10–49 at ₹2,200, 50+ at ₹1,950). The app nudges buyers toward the next slab.
- **Buy now, pay later.** Each buyer has a credit limit. Orders use credit; payments restore it.
- **Nothing gets lost.** Every stock movement is logged automatically by the database.

---

## Which SQL file do I use?

| Your database server | File |
|---|---|
| MySQL Server 8.0 / 8.4 (used with MySQL Workbench) | `database/trinetra_mysql8.sql` |
| XAMPP (MariaDB) | `database/trinetra.sql` |
| Cloud MySQL 8 (Aiven, Railway) for a live deployment | `database/trinetra_cloud.sql` |

The two files are identical except for 4 lines of role syntax in section 9. Run `SELECT VERSION();` if you are unsure: a result containing "MariaDB" means XAMPP.

### Running it in MySQL Workbench
1. Open the connection to your server (usually "Local instance MySQL80") and enter the root password.
2. File → Open SQL Script → pick the right file from the table above.
3. Click the plain lightning icon (Execute all). Check the Output panel at the bottom: all green ticks, no red crosses.
4. Click the refresh icon in the Schemas panel; `trinetra_db` appears.
5. Optional: Database → Reverse Engineer → `trinetra_db` draws the ER diagram automatically.

---

## Requirements

| Software | Version | Note |
|---|---|---|
| XAMPP | Any recent version | Uses its MariaDB (10.4 or newer). Only the **MySQL** module needs to be running; Apache is not needed. |
| Node.js | 18 or newer | `node -v` to check |

---

## Setup (about 5 minutes)

**1. Start the database.** Open the XAMPP Control Panel and click **Start** next to **MySQL**. It should turn green.

**2. Create the database.** Open Command Prompt in the `trinetra` folder and run:
```
C:\xampp\mysql\bin\mysql.exe -u root < database\trinetra.sql
```
(If your XAMPP root user has a password, add `-p` after `root`.) A lot of table output scrolls past; that is normal. If it ends without an `ERROR` line, it worked.

Backup option: phpMyAdmin (http://localhost/phpmyadmin, needs Apache started) → Import tab → choose `database/trinetra.sql` → Import.

**3. Install and start the website**, in the same folder:
```
npm install
npm start
```
You should see:
```
Connected to MySQL as trinetra_app@localhost
Trinetra is running at http://localhost:3000
```

**4. Open** http://localhost:3000 in a browser.

**To reset all data before the demo,** run the command in step 2 again. It drops and recreates everything.

### If something goes wrong

| Problem | Fix |
|---|---|
| `Cannot find module 'mysql2/promise'` | Run `npm install` in the trinetra folder first. |
| `ECONNREFUSED 127.0.0.1:3306` | MySQL is not started in the XAMPP Control Panel. |
| `Access denied for user 'trinetra_app'` | Step 2 did not finish. Run it again and check for an ERROR line. As a last resort, set `user: 'root'` and `password: ''` in `DB_CONFIG` at the top of `server.js`. |
| XAMPP MySQL will not start (port 3306 busy) | Another MySQL is already running. Stop it in Windows Services, or change the port in XAMPP and in `DB_CONFIG`. |
| Port 3000 busy | `set PORT=4000 && npm start` |
| Fonts look plain | The two Google Fonts need internet. Without it, the app falls back to system fonts and still works. |

---

## Deploying live (summary)

1. **Database:** create a free MySQL service on Aiven (or Railway). Connect MySQL Workbench to it with SSL and run `database/trinetra_cloud.sql`. On Aiven, if you get error 1419, enable `log_bin_trust_function_creators` in the service's Advanced configuration, then run the script again.
2. **Change the app password** (the default is public on GitHub): `ALTER USER 'trinetra_app'@'%' IDENTIFIED BY '<new password>';`
3. **Code:** upload the project to a GitHub repository (without `node_modules`).
4. **Website:** on Render, create a Web Service from the repository. Build `npm install`, start `npm start`, plan Free. Environment variables: `DB_HOST`, `DB_PORT`, `DB_USER=trinetra_app`, `DB_PASSWORD`, `DB_SSL=true`.
5. Open the `onrender.com` URL. Free services sleep after 15 minutes idle; the first visit takes about a minute.

---

## Project structure

```
trinetra/
├── database/trinetra.sql         all SQL for XAMPP / MariaDB
├── database/trinetra_mysql8.sql  same, for MySQL Server 8 (Workbench)
├── database/trinetra_cloud.sql   same, for a cloud MySQL 8 database (live deployment)
├── server.js               Express API (thin: just calls the database)
├── public/index.html       the whole frontend (HTML, CSS and plain JavaScript)
├── docs/er-diagram.dbml    paste into dbdiagram.io to draw the ER diagram
└── package.json
```

**Architecture in one line:** Browser → `fetch()` → Express route → `CALL procedure` / `SELECT view` → MariaDB (XAMPP).

All business rules live **in the database**, not in JavaScript. Even if someone bypasses the website and connects to MySQL directly, they cannot oversell stock, overspend credit or create overlapping price slabs.

---

## The 5-minute demo script

Do these in order during the evaluation. Click **View SQL** after each step to show the exact query or procedure call.

1. **Overview.** Show gross sales, receivables, buyer savings and the supplier ranking. Mention the ranking uses `RANK() OVER (...)`, a window function.
2. **Tier pricing.** Marketplace, buying as D-Mart. On the Havells fan, type 9, then 10, then 50. The highlighted slab moves and the price drops ₹2,500 → ₹2,200 → ₹1,950. The nudge says how much more to buy to save.
3. **Successful order.** Add 50 fans and 100 bags of atta, open the cart, place the order. A toast shows the order number; D-Mart's credit drops in the top bar.
4. **Rejected order (the best moment).** Switch to Osia Hypermart (credit ₹2.5 L). Add 60 cartons of Tata Tea (₹2.52 L). The cart warns that MySQL will reject it. Place it anyway: the database refuses with *"total exceeds available credit"*, and View SQL shows the rejected CALL. Nothing was saved: that is the transaction rollback.
5. **Payment.** Orders → open #12 (Spencer's, unpaid) → record a ₹50,000 NEFT payment. Status becomes Partially paid. Buyers page: Spencer's credit went up by ₹50,000.
6. **Cancellation.** Open the order you placed in step 3 → Cancel. Stock and credit come back.
7. **Audit trail.** Stock ledger page: your sale and the cancellation appear automatically, written by a trigger. Receive stock for Fortune Sunflower Oil and watch it leave the "Needs restock" list.
8. **Security (optional).** Log in as the app user with `C:\xampp\mysql\bin\mysql.exe -u trinetra_app -p trinetra_db` (password `Trinetra@2026`) and try `UPDATE Products SET stock_quantity = 0;`. It fails with "UPDATE command denied". The app can only change data through procedures.

---

## Where each DBMS concept is used

| Concept | Where | What to say |
|---|---|---|
| 3NF normalization | All 9 tables | No repeating groups, no partial or transitive dependency. Payments has no buyer_id because order_id already determines the buyer. |
| PK, FK, UNIQUE, NOT NULL, DEFAULT | Every table | GSTIN, email and SKU are unique business keys. |
| CHECK constraints | Credit, stock, rating, status, payment mode, tier range | `available_credit BETWEEN 0 AND credit_limit` makes negative credit impossible. |
| Referential actions | `ON DELETE RESTRICT` / `CASCADE` | Orders and payments are financial records, so RESTRICT. Price tiers belong to a product, so CASCADE. |
| Generated columns | `Order_Items.subtotal`, `Stock_Ledger.change_qty` | Computed by MySQL, so they can never disagree with their inputs. |
| Indexes | `idx_orders_status_date`, `idx_ledger_product_time`, unique keys | UNIQUE and FK columns are indexed automatically by InnoDB. |
| Stored functions | `fn_get_tier_price`, `fn_order_paid` | Reusable logic, called from procedures and from the website's price check. |
| Stored procedures | `PlaceOrder`, `RecordPayment`, `CancelOrder`, `FulfillOrder`, `RestockProduct` | All writes go through these. |
| Transactions (ACID) | `PlaceOrder`, `RecordPayment`, `CancelOrder` | `START TRANSACTION` … `COMMIT`; `EXIT HANDLER` does `ROLLBACK` on any error. |
| Concurrency control | `SELECT ... FOR UPDATE` in procedures | Row locks stop two buyers from buying the same last units or spending the same credit. Rows are locked in product_id order to prevent deadlocks. |
| Cursor | `PlaceOrder` loops over cart lines | `DECLARE CURSOR`, `FETCH`, `NOT FOUND` handler. |
| JSON + temporary table | `PlaceOrder(buyer, '[{...}]')` | One call places an order with many products. `JSON_VALUE` reads each cart line into a temporary table, which the cursor then loops over. |
| Error handling | `SIGNAL SQLSTATE '45000'`, `RESIGNAL` | Custom messages travel all the way to the website toast. |
| Triggers | Stock audit, opening stock, tier overlap (insert and update) | The overlap rule needs to look at other rows, which a CHECK cannot do. |
| Views | 5 views, including a view built on a view | Hide joins; the viewer role can see only views. |
| Joins, GROUP BY, HAVING, subqueries | Report queries R1–R7, dashboard | R3 uses NOT EXISTS; R2 uses HAVING. |
| Window functions | Supplier ranking | `RANK() OVER (ORDER BY revenue DESC)` |
| DCL | Roles `trinetra_app_role`, `trinetra_viewer_role` | GRANT, REVOKE, SET DEFAULT ROLE, least privilege. |

---

## Likely viva questions

**Why is `total_amount` stored if it can be calculated from the items?**
It is the frozen invoice value. It makes order listing fast and it is protected because only `PlaceOrder` sets it. Report R7 proves the stored values stay consistent (mismatch is 0 for every buyer).

**Why store `applied_unit_price` instead of looking up the tier again?**
Tier prices can change next month. The order must keep the price the buyer actually paid.

**What happens if two buyers order the last 10 fans at the same moment?**
The first `SELECT ... FOR UPDATE` locks the product row. The second waits, then sees the updated stock and fails with "only 0 left".

**Why did order numbers skip after a failed order?**
InnoDB does not roll back AUTO_INCREMENT values. A rolled-back order still used up its number. This is normal and is how real banks and shops behave too.

**Why not just put the rules in JavaScript?**
Then anyone connecting to the database directly could skip them. Rules in the database protect the data from every client.

**What is `@stock_reason`?**
A session variable. The procedure sets it before changing stock; the trigger reads it to write the reason into the ledger. A manual UPDATE has no reason set, so it is logged as "Manual adjustment".

**Difference between a function and a procedure here?**
A function returns one value and can be used inside a SELECT (`SELECT fn_get_tier_price(1, 50)`). A procedure is called with CALL, can run transactions and return result sets.

---

Company names are real Indian businesses used for realism; emails, GSTINs and all figures are fictional.
