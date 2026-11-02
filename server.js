// =====================================================================
//  Trinetra backend (Node.js + Express + mysql2)
//
//  The server is deliberately thin. It does NOT contain business rules:
//  stock checks, tier pricing, credit checks and audit logging all live
//  inside MySQL (procedures, functions, triggers). The server only
//  passes requests to the database and returns the results as JSON.
//
//  Every response also includes the exact SQL that ran ("sql" field),
//  so the website can show it with the "View SQL" button.
// =====================================================================

const express = require('express');
const mysql = require('mysql2/promise');
const path = require('path');

// ---- Database connection -------------------------------------------
// trinetra_app may only SELECT and EXECUTE procedures (see section 9 of
// trinetra.sql). Works with XAMPP's MariaDB out of the box.
// If login fails, use user: 'root' and password: '' (XAMPP default).
// When deployed, these come from environment variables set on the host
// (Render dashboard), so no passwords are stored in the code.

// Cloud databases (e.g. Aiven) require SSL. Put the provider's CA
// certificate text in DB_CA to verify the server, or set DB_SSL=true to
// use SSL without verification. Locally neither is set, so SSL is off.
function sslConfig() {
  if (process.env.DB_CA) return { ca: process.env.DB_CA.replace(/\\n/g, '\n') };
  if (process.env.DB_SSL === 'true') return { rejectUnauthorized: false };
  return undefined;
}

const DB_CONFIG = {
  host: process.env.DB_HOST || '127.0.0.1',
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER || 'trinetra_app',
  password: process.env.DB_PASSWORD || 'Trinetra@2026',
  database: process.env.DB_NAME || 'trinetra_db',
  ssl: sslConfig(),
  waitForConnections: true,
  connectionLimit: 10,
  decimalNumbers: true, // DECIMAL columns arrive as JS numbers
  dateStrings: true     // DATETIME arrives as 'YYYY-MM-DD HH:MM:SS'
};

const pool = mysql.createPool(DB_CONFIG);
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ---- Helpers -------------------------------------------------------

// Runs a query with ? placeholders and returns { sql, rows }
async function run(sql, params = []) {
  const finalSql = mysql.format(sql, params); // the exact statement, values filled in
  let result;
  try {
    [result] = await pool.query(finalSql);
  } catch (err) {
    err.attemptedSql = finalSql.replace(/\\"/g, '"'); // so the website can show which statement failed
    throw err;
  }
  // CALL returns [resultSet, okPacket]; plain SELECT returns rows
  const rows = sql.trim().toUpperCase().startsWith('CALL') ? result[0] : result;
  // For display only: \" and " mean the same inside a quoted SQL string
  return { sql: finalSql.replace(/\\"/g, '"'), rows };
}

// Wraps a route so database errors become clean JSON messages.
// Errors raised with SIGNAL (SQLSTATE 45000) or CHECK constraints are
// business-rule failures, so they return 400 with MySQL's own message.
function route(handler) {
  return async (req, res) => {
    try {
      await handler(req, res);
    } catch (err) {
      // 45000 = SIGNAL; 3819 (MySQL) / 4025 (MariaDB) = CHECK constraint failed
      const isRule = err.sqlState === '45000' || err.errno === 3819 || err.errno === 4025;
      console.error(err.sqlMessage || err.message);
      res.status(isRule ? 400 : 500).json({
        error: err.sqlMessage || err.message,
        code: err.code || null,
        sql: err.attemptedSql || null
      });
    }
  };
}

// ---- Read endpoints ------------------------------------------------

app.get('/api/health', route(async (req, res) => {
  const r = await run('SELECT DATABASE() AS db, VERSION() AS version, CURRENT_USER() AS user');
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.get('/api/dashboard', route(async (req, res) => {
  const kpi = await run(`
    SELECT
      (SELECT COALESCE(SUM(total_amount), 0) FROM Purchase_Orders WHERE status <> 'Cancelled') AS gross_sales,
      (SELECT COUNT(*) FROM Purchase_Orders WHERE status <> 'Cancelled')                      AS orders,
      (SELECT COALESCE(SUM(outstanding), 0) FROM vw_order_summary)                            AS receivables,
      (SELECT COUNT(*) FROM vw_low_stock)                                                     AS low_stock,
      (SELECT COALESCE(SUM((p.base_unit_price - i.applied_unit_price) * i.quantity), 0)
         FROM Order_Items i
         JOIN Products p        ON p.product_id = i.product_id
         JOIN Purchase_Orders o ON o.order_id   = i.order_id
        WHERE o.status <> 'Cancelled')                                                        AS buyer_savings`);

  const monthly = await run(`
    SELECT DATE_FORMAT(order_date, '%Y-%m') AS month,
           COUNT(*) AS orders, SUM(total_amount) AS revenue
    FROM Purchase_Orders
    WHERE status <> 'Cancelled'
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
    ORDER BY month`);

  const suppliers = await run(`
    SELECT company_name, revenue, units_sold,
           RANK() OVER (ORDER BY revenue DESC) AS sales_rank
    FROM vw_supplier_sales`);

  const categories = await run(`
    SELECT c.category_name, SUM(i.subtotal) AS revenue
    FROM Order_Items i
    JOIN Products p        ON p.product_id  = i.product_id
    JOIN Categories c      ON c.category_id = p.category_id
    JOIN Purchase_Orders o ON o.order_id    = i.order_id
    WHERE o.status <> 'Cancelled'
    GROUP BY c.category_id, c.category_name
    ORDER BY revenue DESC`);

  const topBuyers = await run(`
    SELECT b.company_name, COUNT(*) AS orders, SUM(o.total_amount) AS spend
    FROM Purchase_Orders o
    JOIN Wholesale_Buyers b ON b.buyer_id = o.buyer_id
    WHERE o.status <> 'Cancelled'
    GROUP BY b.buyer_id, b.company_name
    HAVING SUM(o.total_amount) > 100000
    ORDER BY spend DESC`);

  const lowStock = await run('SELECT * FROM vw_low_stock ORDER BY stock_quantity');

  res.json({
    sql: [kpi.sql, monthly.sql, suppliers.sql, categories.sql, topBuyers.sql, lowStock.sql],
    data: {
      kpi: kpi.rows[0],
      monthly: monthly.rows,
      suppliers: suppliers.rows,
      categories: categories.rows,
      topBuyers: topBuyers.rows,
      lowStock: lowStock.rows
    }
  });
}));

app.get('/api/products', route(async (req, res) => {
  const products = await run('SELECT * FROM vw_product_catalog ORDER BY category_name, product_name');
  const tiers = await run(`
    SELECT tier_id, product_id, min_quantity, max_quantity, discounted_unit_price
    FROM Price_Tiers ORDER BY product_id, min_quantity`);
  res.json({ sql: [products.sql, tiers.sql], data: { products: products.rows, tiers: tiers.rows } });
}));

// Live price check through the stored function
app.get('/api/price', route(async (req, res) => {
  const r = await run('SELECT fn_get_tier_price(?, ?) AS unit_price',
    [Number(req.query.product_id), Number(req.query.qty)]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.get('/api/buyers', route(async (req, res) => {
  const r = await run('SELECT * FROM vw_buyer_credit ORDER BY company_name');
  res.json({ sql: r.sql, data: r.rows });
}));

app.get('/api/suppliers', route(async (req, res) => {
  const r = await run(`
    SELECT v.*, s.email, s.gstin,
           RANK() OVER (ORDER BY v.revenue DESC) AS sales_rank
    FROM vw_supplier_sales v
    JOIN Suppliers s ON s.supplier_id = v.supplier_id
    ORDER BY sales_rank`);
  res.json({ sql: r.sql, data: r.rows });
}));

app.get('/api/orders', route(async (req, res) => {
  const r = await run('SELECT * FROM vw_order_summary ORDER BY order_id DESC');
  res.json({ sql: r.sql, data: r.rows });
}));

app.get('/api/orders/:id', route(async (req, res) => {
  const id = Number(req.params.id);
  const summary = await run('SELECT * FROM vw_order_summary WHERE order_id = ?', [id]);
  const items = await run(`
    SELECT i.item_id, p.product_name, p.sku, p.unit, p.base_unit_price,
           i.quantity, i.applied_unit_price, i.subtotal
    FROM Order_Items i
    JOIN Products p ON p.product_id = i.product_id
    WHERE i.order_id = ?
    ORDER BY i.item_id`, [id]);
  const payments = await run(
    'SELECT payment_id, amount, payment_mode, reference_no, paid_at FROM Payments WHERE order_id = ? ORDER BY paid_at',
    [id]);
  if (!summary.rows.length) return res.status(404).json({ error: 'Order not found' });
  res.json({
    sql: [summary.sql, items.sql, payments.sql],
    data: { order: summary.rows[0], items: items.rows, payments: payments.rows }
  });
}));

app.get('/api/stock-ledger', route(async (req, res) => {
  const r = await run(`
    SELECT l.ledger_id, l.changed_at, p.product_name, p.sku,
           l.old_quantity, l.new_quantity, l.change_qty, l.reason
    FROM Stock_Ledger l
    JOIN Products p ON p.product_id = l.product_id
    ORDER BY l.changed_at DESC, l.ledger_id DESC
    LIMIT 200`);
  res.json({ sql: r.sql, data: r.rows });
}));

// ---- Write endpoints: every write is a stored procedure -------------

app.post('/api/orders', route(async (req, res) => {
  const { buyer_id, items } = req.body;
  const r = await run('CALL PlaceOrder(?, ?)', [Number(buyer_id), JSON.stringify(items || [])]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.post('/api/orders/:id/pay', route(async (req, res) => {
  const { amount, mode, reference } = req.body;
  const r = await run('CALL RecordPayment(?, ?, ?, ?)',
    [Number(req.params.id), Number(amount), mode, reference || null]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.post('/api/orders/:id/cancel', route(async (req, res) => {
  const r = await run('CALL CancelOrder(?)', [Number(req.params.id)]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.post('/api/orders/:id/fulfil', route(async (req, res) => {
  const r = await run('CALL FulfillOrder(?)', [Number(req.params.id)]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

app.post('/api/products/:id/restock', route(async (req, res) => {
  const r = await run('CALL RestockProduct(?, ?)', [Number(req.params.id), Number(req.body.qty)]);
  res.json({ sql: r.sql, data: r.rows[0] });
}));

// ---- Start ---------------------------------------------------------
const PORT = Number(process.env.PORT || 3000);
app.listen(PORT, async () => {
  try {
    const [rows] = await pool.query('SELECT CURRENT_USER() AS u');
    console.log(`Connected to MySQL as ${rows[0].u}`);
  } catch (e) {
    console.error('Could not connect to MySQL:', e.message);
    console.error('Check DB_CONFIG at the top of server.js');
  }
  console.log(`Trinetra is running at http://localhost:${PORT}`);
});
