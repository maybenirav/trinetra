-- =====================================================================
--  TRINETRA  |  B2B Wholesale Marketplace Database
--  Tier pricing  +  credit-based buying  +  full audit trail
--
--  CLOUD version for a hosted MySQL 8 database (e.g. Aiven).
--  Connect MySQL Workbench to the cloud database as its admin user
--  (avnadmin on Aiven, with SSL) and click Execute (the lightning icon).
--  Differences from trinetra_mysql8.sql: the app and viewer users accept
--  connections from any host ('%'), because the website runs on another
--  server.
--  Uses CHECK constraints, JSON functions, window functions and roles.
--
--  WARNING: this script DROPS and recreates trinetra_db, so running it
--  again is also the quickest way to reset the demo data.
--
--  Sections
--    1. Database
--    2. Tables (3NF) and indexes
--    3. Functions
--    4. Triggers
--    5. Stored procedures (transactions, cursor, locking)
--    6. Views
--    7. Seed data (real Indian businesses, orders placed via procedures)
--    8. Report queries for the viva
--    9. Access control (DCL: roles and users)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. DATABASE
-- ---------------------------------------------------------------------
-- MySQL Workbench turns on "safe updates" by default, which blocks the
-- bulk UPDATEs in the seed section. Turn it off for this session only.
SET SQL_SAFE_UPDATES = 0;

DROP DATABASE IF EXISTS trinetra_db;
CREATE DATABASE trinetra_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE trinetra_db;


-- ---------------------------------------------------------------------
-- 2. TABLES
-- Every non-key column depends on the key, the whole key, and nothing
-- but the key (3NF). Example: Payments has no buyer_id, because the
-- buyer is already known through order_id. Storing it again would be a
-- transitive dependency.
-- ---------------------------------------------------------------------

CREATE TABLE Categories (
    category_id   INT AUTO_INCREMENT PRIMARY KEY,
    category_name VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE Suppliers (
    supplier_id  INT AUTO_INCREMENT PRIMARY KEY,
    company_name VARCHAR(100) NOT NULL,
    email        VARCHAR(100) NOT NULL UNIQUE,
    city         VARCHAR(60)  NOT NULL,
    gstin        CHAR(15)     NOT NULL UNIQUE,          -- Indian GST number
    rating       DECIMAL(3,2) NOT NULL DEFAULT 5.00,
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_supplier_rating CHECK (rating BETWEEN 0.00 AND 5.00)
);

CREATE TABLE Wholesale_Buyers (
    buyer_id         INT AUTO_INCREMENT PRIMARY KEY,
    company_name     VARCHAR(100)  NOT NULL,
    contact_email    VARCHAR(100)  NOT NULL UNIQUE,
    city             VARCHAR(60)   NOT NULL,
    gstin            CHAR(15)      NOT NULL UNIQUE,
    credit_limit     DECIMAL(12,2) NOT NULL DEFAULT 50000.00,
    available_credit DECIMAL(12,2) NOT NULL DEFAULT 50000.00,
    created_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_credit_limit CHECK (credit_limit > 0),
    -- available credit can never go negative or above the sanctioned limit
    CONSTRAINT chk_available_credit CHECK (available_credit >= 0 AND available_credit <= credit_limit)
);

CREATE TABLE Products (
    product_id      INT AUTO_INCREMENT PRIMARY KEY,
    supplier_id     INT           NOT NULL,
    category_id     INT           NOT NULL,
    product_name    VARCHAR(150)  NOT NULL,
    sku             VARCHAR(50)   NOT NULL UNIQUE,
    unit            VARCHAR(20)   NOT NULL DEFAULT 'piece',   -- piece, bag, carton, crate, tin
    base_unit_price DECIMAL(10,2) NOT NULL,
    stock_quantity  INT           NOT NULL DEFAULT 0,
    reorder_level   INT           NOT NULL DEFAULT 50,        -- below this = low stock
    -- RESTRICT: a supplier or category that still has products cannot be deleted
    CONSTRAINT fk_product_supplier FOREIGN KEY (supplier_id) REFERENCES Suppliers(supplier_id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_category FOREIGN KEY (category_id) REFERENCES Categories(category_id) ON DELETE RESTRICT,
    CONSTRAINT chk_base_price    CHECK (base_unit_price > 0),
    CONSTRAINT chk_stock         CHECK (stock_quantity >= 0),
    CONSTRAINT chk_reorder_level CHECK (reorder_level >= 0)
);

CREATE TABLE Price_Tiers (
    tier_id               INT AUTO_INCREMENT PRIMARY KEY,
    product_id            INT           NOT NULL,
    min_quantity          INT           NOT NULL,
    max_quantity          INT           DEFAULT NULL,         -- NULL means "and above"
    discounted_unit_price DECIMAL(10,2) NOT NULL,
    -- tiers belong to the product, so they go when the product goes
    CONSTRAINT fk_tier_product FOREIGN KEY (product_id) REFERENCES Products(product_id) ON DELETE CASCADE,
    CONSTRAINT chk_tier_min   CHECK (min_quantity > 0),
    CONSTRAINT chk_tier_range CHECK (max_quantity IS NULL OR max_quantity >= min_quantity),
    CONSTRAINT chk_tier_price CHECK (discounted_unit_price > 0),
    CONSTRAINT uq_tier_start  UNIQUE (product_id, min_quantity)   -- also serves as the lookup index
    -- Overlapping slabs (e.g. 1-20 and 10-50) need a look at OTHER rows,
    -- which a CHECK cannot do, so a trigger enforces that (section 4).
);

CREATE TABLE Purchase_Orders (
    order_id     INT AUTO_INCREMENT PRIMARY KEY,
    buyer_id     INT           NOT NULL,
    order_date   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0.00,   -- frozen invoice value at order time
    status       VARCHAR(20)   NOT NULL DEFAULT 'Pending',
    -- RESTRICT: a buyer's order history is a financial record and must never vanish
    CONSTRAINT fk_order_buyer FOREIGN KEY (buyer_id) REFERENCES Wholesale_Buyers(buyer_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_total  CHECK (total_amount >= 0),
    CONSTRAINT chk_order_status CHECK (status IN ('Pending', 'Approved', 'Fulfilled', 'Cancelled'))
);

CREATE TABLE Order_Items (
    item_id            INT AUTO_INCREMENT PRIMARY KEY,
    order_id           INT           NOT NULL,
    product_id         INT           NOT NULL,
    quantity           INT           NOT NULL,
    applied_unit_price DECIMAL(10,2) NOT NULL,   -- snapshot: tier prices may change later
    -- Generated column: computed by MySQL, can never disagree with qty x price
    subtotal           DECIMAL(12,2) GENERATED ALWAYS AS (quantity * applied_unit_price) STORED,
    CONSTRAINT fk_item_order   FOREIGN KEY (order_id)   REFERENCES Purchase_Orders(order_id) ON DELETE CASCADE,
    CONSTRAINT fk_item_product FOREIGN KEY (product_id) REFERENCES Products(product_id)       ON DELETE RESTRICT,
    CONSTRAINT chk_item_qty   CHECK (quantity > 0),
    CONSTRAINT chk_item_price CHECK (applied_unit_price > 0)
);

CREATE TABLE Payments (
    payment_id   INT AUTO_INCREMENT PRIMARY KEY,
    order_id     INT           NOT NULL,
    amount       DECIMAL(12,2) NOT NULL,
    payment_mode VARCHAR(10)   NOT NULL,
    reference_no VARCHAR(40),
    paid_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_payment_order FOREIGN KEY (order_id) REFERENCES Purchase_Orders(order_id) ON DELETE RESTRICT,
    CONSTRAINT chk_payment_amount CHECK (amount > 0),
    CONSTRAINT chk_payment_mode   CHECK (payment_mode IN ('UPI', 'NEFT', 'RTGS', 'Cheque'))
);

-- Filled ONLY by triggers: every stock change, with old value, new value and reason
CREATE TABLE Stock_Ledger (
    ledger_id    INT AUTO_INCREMENT PRIMARY KEY,
    product_id   INT          NOT NULL,
    old_quantity INT          NOT NULL,
    new_quantity INT          NOT NULL,
    change_qty   INT GENERATED ALWAYS AS (new_quantity - old_quantity) STORED,
    reason       VARCHAR(100) NOT NULL,
    changed_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ledger_product FOREIGN KEY (product_id) REFERENCES Products(product_id) ON DELETE CASCADE
);

-- Indexes for the most frequent lookups.
-- (UNIQUE columns and foreign keys are indexed by InnoDB automatically,
--  so sku, buyer_id etc. need no extra index.)
CREATE INDEX idx_orders_status_date ON Purchase_Orders (status, order_date);
CREATE INDEX idx_ledger_product_time ON Stock_Ledger (product_id, changed_at);


-- ---------------------------------------------------------------------
-- 3. FUNCTIONS
-- ---------------------------------------------------------------------
DELIMITER //

-- Returns the unit price a buyer pays for a given quantity.
-- Picks the slab whose range contains the quantity; falls back to the
-- base price if the product has no matching slab.
CREATE FUNCTION fn_get_tier_price(p_product_id INT, p_qty INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_price DECIMAL(10,2);

    -- A scalar subquery returns NULL when no row matches (no error, no warning)
    SET v_price = (
        SELECT discounted_unit_price
        FROM Price_Tiers
        WHERE product_id = p_product_id
          AND p_qty >= min_quantity
          AND (max_quantity IS NULL OR p_qty <= max_quantity)
        ORDER BY min_quantity DESC
        LIMIT 1
    );

    IF v_price IS NULL THEN
        SET v_price = (SELECT base_unit_price FROM Products WHERE product_id = p_product_id);
    END IF;

    RETURN v_price;
END //

-- Total amount already paid against an order
CREATE FUNCTION fn_order_paid(p_order_id INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    RETURN (SELECT COALESCE(SUM(amount), 0) FROM Payments WHERE order_id = p_order_id);
END //

DELIMITER ;


-- ---------------------------------------------------------------------
-- 4. TRIGGERS
-- ---------------------------------------------------------------------
DELIMITER //

-- Opening stock of a new product goes into the ledger
CREATE TRIGGER trg_stock_opening
AFTER INSERT ON Products
FOR EACH ROW
BEGIN
    INSERT INTO Stock_Ledger (product_id, old_quantity, new_quantity, reason)
    VALUES (NEW.product_id, 0, NEW.stock_quantity, 'Opening stock');
END //

-- Every stock change is logged automatically. Procedures set the session
-- variable @stock_reason (e.g. 'Sale - Order #12') before updating stock;
-- a direct UPDATE by hand is logged as 'Manual adjustment'.
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON Products
FOR EACH ROW
BEGIN
    IF OLD.stock_quantity <> NEW.stock_quantity THEN
        INSERT INTO Stock_Ledger (product_id, old_quantity, new_quantity, reason)
        VALUES (NEW.product_id, OLD.stock_quantity, NEW.stock_quantity,
                COALESCE(@stock_reason, 'Manual adjustment'));
    END IF;
END //

-- Blocks a new price slab that overlaps an existing slab of the same product.
-- Two ranges [a,b] and [c,d] overlap when a <= d AND c <= b.
-- NULL max means "no upper limit", so it is treated as the largest INT.
CREATE TRIGGER trg_tier_no_overlap_insert
BEFORE INSERT ON Price_Tiers
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM Price_Tiers t
        WHERE t.product_id = NEW.product_id
          AND NEW.min_quantity <= COALESCE(t.max_quantity, 2147483647)
          AND t.min_quantity   <= COALESCE(NEW.max_quantity, 2147483647)
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This price slab overlaps an existing slab for the same product';
    END IF;
END //

-- Same rule when an existing slab is edited (ignoring the row itself)
CREATE TRIGGER trg_tier_no_overlap_update
BEFORE UPDATE ON Price_Tiers
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM Price_Tiers t
        WHERE t.product_id = NEW.product_id
          AND t.tier_id   <> NEW.tier_id
          AND NEW.min_quantity <= COALESCE(t.max_quantity, 2147483647)
          AND t.min_quantity   <= COALESCE(NEW.max_quantity, 2147483647)
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This price slab overlaps an existing slab for the same product';
    END IF;
END //

DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. STORED PROCEDURES
-- ---------------------------------------------------------------------
DELIMITER //

-- PlaceOrder: one order with many products, all-or-nothing.
--   p_items is a JSON array, e.g. '[{"product_id":1,"qty":50},{"product_id":5,"qty":100}]'
-- Steps
--   1. Validate input and copy the JSON cart into a temporary table
--   2. START TRANSACTION
--   3. Lock the buyer row        (SELECT ... FOR UPDATE)
--   4. Cursor over cart lines    (lock product, check stock, tier price, insert line, reduce stock)
--   5. Check credit against the final total
--   6. Approve order, deduct credit, COMMIT
-- Any error at any step -> EXIT HANDLER -> ROLLBACK, so stock, credit and
-- the order header are never left half-updated.
CREATE PROCEDURE PlaceOrder(IN p_buyer_id INT, IN p_items LONGTEXT)
BEGIN
    DECLARE v_done       INT DEFAULT 0;
    DECLARE v_i          INT DEFAULT 0;
    DECLARE v_count      INT DEFAULT 0;
    DECLARE v_product_id INT;
    DECLARE v_qty        INT;
    DECLARE v_stock      INT;
    DECLARE v_name       VARCHAR(150);
    DECLARE v_price      DECIMAL(10,2);
    DECLARE v_total      DECIMAL(12,2) DEFAULT 0;
    DECLARE v_credit     DECIMAL(12,2);
    DECLARE v_order_id   INT;
    DECLARE v_lines      INT DEFAULT 0;
    DECLARE v_msg        VARCHAR(128);

    -- The cursor reads the cart from a temporary table (filled in step 1).
    -- GROUP BY merges repeated products so the tier price applies to the
    -- combined quantity. ORDER BY product_id makes every order lock rows in
    -- the same order, which prevents deadlocks between simultaneous orders.
    DECLARE cur_items CURSOR FOR
        SELECT product_id, SUM(qty)
        FROM tmp_cart
        GROUP BY product_id
        ORDER BY product_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @stock_reason = NULL;
        DROP TEMPORARY TABLE IF EXISTS tmp_cart;
        RESIGNAL;               -- pass the original error message to the caller
    END;

    -- 1. Validation
    IF p_items IS NULL OR JSON_VALID(p_items) = 0 OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order failed: the cart is empty';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM Wholesale_Buyers WHERE buyer_id = p_buyer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order failed: buyer does not exist';
    END IF;

    -- Copy the JSON array into a temporary table, one row per cart line.
    -- JSON_EXTRACT(p_items, '$[0].qty') reads the qty of the first line, etc.
    DROP TEMPORARY TABLE IF EXISTS tmp_cart;
    CREATE TEMPORARY TABLE tmp_cart (line_no INT AUTO_INCREMENT PRIMARY KEY, product_id INT, qty INT);

    SET v_count = JSON_LENGTH(p_items);
    WHILE v_i < v_count DO
        INSERT INTO tmp_cart (product_id, qty) VALUES (
            CAST(JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].product_id'))) AS SIGNED),
            CAST(JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_i, '].qty')))        AS SIGNED));
        SET v_i = v_i + 1;
    END WHILE;

    IF EXISTS (SELECT 1 FROM tmp_cart WHERE product_id IS NULL OR qty IS NULL OR qty <= 0) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order failed: every cart line needs a product and a quantity of at least 1';
    END IF;

    -- 2. Transaction
    START TRANSACTION;

    -- 3. Lock the buyer so no other order can spend the same credit meanwhile
    SELECT available_credit INTO v_credit
    FROM Wholesale_Buyers WHERE buyer_id = p_buyer_id
    FOR UPDATE;

    INSERT INTO Purchase_Orders (buyer_id, total_amount, status)
    VALUES (p_buyer_id, 0, 'Pending');
    SET v_order_id    = LAST_INSERT_ID();
    SET @stock_reason = CONCAT('Sale - Order #', v_order_id);   -- read by trg_stock_audit

    -- 4. Cursor over the cart
    SET v_done = 0;
    OPEN cur_items;
    item_loop: LOOP
        FETCH cur_items INTO v_product_id, v_qty;
        IF v_done = 1 THEN
            LEAVE item_loop;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM Products WHERE product_id = v_product_id) THEN
            SET v_msg = CONCAT('Order failed: product #', v_product_id, ' does not exist');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        -- Lock the product row so two buyers cannot buy the same last units
        SELECT stock_quantity, product_name INTO v_stock, v_name
        FROM Products WHERE product_id = v_product_id
        FOR UPDATE;

        IF v_stock < v_qty THEN
            SET v_msg = CONCAT('Order failed: only ', v_stock, ' left of ', LEFT(v_name, 60));
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        SET v_price = fn_get_tier_price(v_product_id, v_qty);

        INSERT INTO Order_Items (order_id, product_id, quantity, applied_unit_price)
        VALUES (v_order_id, v_product_id, v_qty, v_price);

        UPDATE Products
        SET stock_quantity = stock_quantity - v_qty
        WHERE product_id = v_product_id;          -- fires trg_stock_audit

        SET v_total = v_total + (v_price * v_qty);
        SET v_lines = v_lines + 1;
    END LOOP;
    CLOSE cur_items;

    -- 5. Credit check on the final total
    IF v_credit < v_total THEN
        SET v_msg = CONCAT('Order failed: total Rs.', v_total, ' exceeds available credit Rs.', v_credit);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- 6. Approve, deduct credit, commit
    UPDATE Purchase_Orders
    SET total_amount = v_total, status = 'Approved'
    WHERE order_id = v_order_id;

    UPDATE Wholesale_Buyers
    SET available_credit = available_credit - v_total
    WHERE buyer_id = p_buyer_id;

    COMMIT;
    SET @stock_reason = NULL;
    DROP TEMPORARY TABLE IF EXISTS tmp_cart;

    SELECT v_order_id           AS order_id,
           p_buyer_id           AS buyer_id,
           v_lines              AS line_items,
           v_total              AS total_amount,
           v_credit - v_total   AS credit_remaining,
           'Order approved'     AS message;
END //


-- The original single-product demo call still works:
--   CALL ProcessWholesaleOrder(1, 1, 50);
CREATE PROCEDURE ProcessWholesaleOrder(IN p_buyer_id INT, IN p_product_id INT, IN p_quantity INT)
BEGIN
    CALL PlaceOrder(p_buyer_id, JSON_ARRAY(JSON_OBJECT('product_id', p_product_id, 'qty', p_quantity)));
END //


-- RecordPayment: buyer pays (fully or partly) against an order.
-- The paid amount is added back to the buyer's available credit.
CREATE PROCEDURE RecordPayment(
    IN p_order_id INT,
    IN p_amount   DECIMAL(12,2),
    IN p_mode     VARCHAR(10),
    IN p_ref      VARCHAR(40)
)
BEGIN
    DECLARE v_status      VARCHAR(20);
    DECLARE v_total       DECIMAL(12,2);
    DECLARE v_buyer       INT;
    DECLARE v_outstanding DECIMAL(12,2);
    DECLARE v_payment_id  INT;
    DECLARE v_msg         VARCHAR(128);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT EXISTS (SELECT 1 FROM Purchase_Orders WHERE order_id = p_order_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment failed: order does not exist';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment failed: amount must be greater than zero';
    END IF;

    START TRANSACTION;

    SELECT status, total_amount, buyer_id INTO v_status, v_total, v_buyer
    FROM Purchase_Orders WHERE order_id = p_order_id
    FOR UPDATE;

    IF v_status = 'Cancelled' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment failed: this order is cancelled';
    END IF;

    SET v_outstanding = v_total - fn_order_paid(p_order_id);

    IF p_amount > v_outstanding THEN
        SET v_msg = CONCAT('Payment failed: only Rs.', v_outstanding, ' is outstanding on this order');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    INSERT INTO Payments (order_id, amount, payment_mode, reference_no)
    VALUES (p_order_id, p_amount, p_mode, p_ref);
    SET v_payment_id = LAST_INSERT_ID();

    UPDATE Wholesale_Buyers
    SET available_credit = available_credit + p_amount
    WHERE buyer_id = v_buyer;

    COMMIT;

    SELECT v_payment_id               AS payment_id,
           p_order_id                 AS order_id,
           p_amount                   AS amount_paid,
           v_outstanding - p_amount   AS still_outstanding,
           'Payment recorded'         AS message;
END //


-- CancelOrder: only an Approved order with no payments can be cancelled.
-- Stock goes back to the shelf and the credit goes back to the buyer.
CREATE PROCEDURE CancelOrder(IN p_order_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_total  DECIMAL(12,2);
    DECLARE v_buyer  INT;
    DECLARE v_msg    VARCHAR(128);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @stock_reason = NULL;
        RESIGNAL;
    END;

    IF NOT EXISTS (SELECT 1 FROM Purchase_Orders WHERE order_id = p_order_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cancel failed: order does not exist';
    END IF;

    START TRANSACTION;

    SELECT status, total_amount, buyer_id INTO v_status, v_total, v_buyer
    FROM Purchase_Orders WHERE order_id = p_order_id
    FOR UPDATE;

    IF v_status <> 'Approved' THEN
        SET v_msg = CONCAT('Cancel failed: only Approved orders can be cancelled (this one is ', v_status, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF fn_order_paid(p_order_id) > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cancel failed: payments are already recorded on this order';
    END IF;

    SET @stock_reason = CONCAT('Cancellation - Order #', p_order_id);

    -- Multi-table UPDATE: put every line's quantity back in stock
    UPDATE Products p
    JOIN (SELECT product_id, SUM(quantity) AS qty
          FROM Order_Items WHERE order_id = p_order_id
          GROUP BY product_id) x ON x.product_id = p.product_id
    SET p.stock_quantity = p.stock_quantity + x.qty;

    UPDATE Wholesale_Buyers
    SET available_credit = available_credit + v_total
    WHERE buyer_id = v_buyer;

    UPDATE Purchase_Orders SET status = 'Cancelled' WHERE order_id = p_order_id;

    COMMIT;
    SET @stock_reason = NULL;

    SELECT p_order_id AS order_id, v_total AS credit_restored, 'Order cancelled' AS message;
END //


-- FulfillOrder: goods dispatched. Approved -> Fulfilled.
-- A single UPDATE is already atomic, so no explicit transaction is needed.
CREATE PROCEDURE FulfillOrder(IN p_order_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_msg    VARCHAR(128);

    SET v_status = (SELECT status FROM Purchase_Orders WHERE order_id = p_order_id);

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fulfil failed: order does not exist';
    END IF;

    IF v_status <> 'Approved' THEN
        SET v_msg = CONCAT('Fulfil failed: only Approved orders can be fulfilled (this one is ', v_status, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    UPDATE Purchase_Orders SET status = 'Fulfilled' WHERE order_id = p_order_id;

    SELECT p_order_id AS order_id, 'Order marked as fulfilled' AS message;
END //


-- RestockProduct: new stock received from the supplier (logged by trigger)
CREATE PROCEDURE RestockProduct(IN p_product_id INT, IN p_qty INT)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM Products WHERE product_id = p_product_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Restock failed: product does not exist';
    END IF;

    IF p_qty IS NULL OR p_qty <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Restock failed: quantity must be at least 1';
    END IF;

    SET @stock_reason = 'Restock from supplier';
    UPDATE Products SET stock_quantity = stock_quantity + p_qty WHERE product_id = p_product_id;
    SET @stock_reason = NULL;

    SELECT product_id, product_name, stock_quantity AS new_stock, 'Stock updated' AS message
    FROM Products WHERE product_id = p_product_id;
END //

DELIMITER ;


-- ---------------------------------------------------------------------
-- 6. VIEWS
-- Saved queries that hide joins and calculations. The frontend reads
-- mostly from these, and the read-only role can see only these.
-- ---------------------------------------------------------------------

-- Marketplace catalogue with supplier, category, best price and stock status
CREATE VIEW vw_product_catalog AS
SELECT p.product_id,
       p.sku,
       p.product_name,
       c.category_name,
       s.supplier_id,
       s.company_name  AS supplier_name,
       s.city          AS supplier_city,
       s.rating        AS supplier_rating,
       p.unit,
       p.base_unit_price,
       (SELECT MIN(t.discounted_unit_price) FROM Price_Tiers t
        WHERE t.product_id = p.product_id) AS best_unit_price,
       p.stock_quantity,
       p.reorder_level,
       CASE
           WHEN p.stock_quantity = 0                 THEN 'Out of stock'
           WHEN p.stock_quantity <= p.reorder_level  THEN 'Low stock'
           ELSE 'In stock'
       END AS stock_status
FROM Products p
JOIN Suppliers  s ON s.supplier_id = p.supplier_id
JOIN Categories c ON c.category_id = p.category_id;

-- Credit position of every buyer
CREATE VIEW vw_buyer_credit AS
SELECT b.buyer_id,
       b.company_name,
       b.city,
       b.gstin,
       b.credit_limit,
       b.available_credit,
       b.credit_limit - b.available_credit                                AS credit_used,
       ROUND((b.credit_limit - b.available_credit) / b.credit_limit * 100, 1) AS utilisation_pct,
       COUNT(o.order_id)                                                  AS active_orders
FROM Wholesale_Buyers b
LEFT JOIN Purchase_Orders o ON o.buyer_id = b.buyer_id AND o.status <> 'Cancelled'
GROUP BY b.buyer_id;

-- One row per order with item count, amount paid and payment status
CREATE VIEW vw_order_summary AS
SELECT o.order_id,
       o.order_date,
       o.status,
       b.buyer_id,
       b.company_name AS buyer_name,
       COALESCE(it.line_items, 0) AS line_items,
       COALESCE(it.units, 0)      AS units,
       o.total_amount,
       COALESCE(pay.paid, 0)      AS amount_paid,
       CASE WHEN o.status = 'Cancelled' THEN 0
            ELSE o.total_amount - COALESCE(pay.paid, 0) END AS outstanding,
       CASE
           WHEN o.status = 'Cancelled'                 THEN 'Not applicable'
           WHEN COALESCE(pay.paid, 0) = 0              THEN 'Unpaid'
           WHEN COALESCE(pay.paid, 0) < o.total_amount THEN 'Partially paid'
           ELSE 'Paid'
       END AS payment_status
FROM Purchase_Orders o
JOIN Wholesale_Buyers b ON b.buyer_id = o.buyer_id
LEFT JOIN (SELECT order_id, SUM(amount) AS paid
           FROM Payments GROUP BY order_id) pay ON pay.order_id = o.order_id
LEFT JOIN (SELECT order_id, COUNT(*) AS line_items, SUM(quantity) AS units
           FROM Order_Items GROUP BY order_id) it ON it.order_id = o.order_id;

-- Sales performance of every supplier (cancelled orders excluded)
CREATE VIEW vw_supplier_sales AS
SELECT s.supplier_id,
       s.company_name,
       s.city,
       s.rating,
       COUNT(DISTINCT p.product_id) AS products_listed,
       COALESCE(SUM(CASE WHEN o.status <> 'Cancelled' THEN i.quantity END), 0) AS units_sold,
       COALESCE(SUM(CASE WHEN o.status <> 'Cancelled' THEN i.subtotal END), 0) AS revenue
FROM Suppliers s
LEFT JOIN Products        p ON p.supplier_id = s.supplier_id
LEFT JOIN Order_Items     i ON i.product_id  = p.product_id
LEFT JOIN Purchase_Orders o ON o.order_id    = i.order_id
GROUP BY s.supplier_id;

-- Products that need reordering (a view built on another view)
CREATE VIEW vw_low_stock AS
SELECT product_id, sku, product_name, supplier_name, stock_quantity, reorder_level, stock_status
FROM vw_product_catalog
WHERE stock_status <> 'In stock';


-- ---------------------------------------------------------------------
-- 7. SEED DATA
-- Master data is inserted directly. Orders, payments, cancellations and
-- fulfilments go through the procedures, exactly like the live app, so
-- stock, credit and the ledger are consistent from the start.
-- (Company names are real; emails, GSTINs and figures are fictional.)
-- ---------------------------------------------------------------------

INSERT INTO Categories (category_name) VALUES
('Electricals & Lighting'),     -- 1
('Staples & Grocery'),          -- 2
('Beverages'),                  -- 3
('Personal Care'),              -- 4
('Kitchen Appliances');         -- 5

INSERT INTO Suppliers (company_name, email, city, gstin, rating) VALUES
('Reliance Consumer Products', 'b2b@reliancecp.example.in',      'Mumbai',    '27AABCR1718E1ZL', 4.80),  -- 1
('Tata Consumer Products',     'wholesale@tataconsumer.example.in','Kolkata', '19AAACT3518Q1ZW', 4.70),  -- 2
('Havells India Ltd',          'bulk@havells.example.in',        'Noida',     '09AAACH0351E1Z2', 4.60),  -- 3
('Dabur India Ltd',            'trade@dabur.example.in',         'Ghaziabad', '09AAACD0474C1ZQ', 4.50),  -- 4
('Bajaj Electricals Ltd',      'institutional@bajaj.example.in', 'Mumbai',    '27AAACB2484L1Z8', 4.40),  -- 5
('AWL Agri Business Ltd',      'distribution@awl.example.in',    'Ahmedabad', '24AABCA8056G1ZE', 4.60);  -- 6

INSERT INTO Wholesale_Buyers (company_name, contact_email, city, gstin, credit_limit, available_credit) VALUES
('D-Mart Retail Stores',    'procurement@dmart.example.in',  'Mumbai',    '27AACCA8432H1ZQ',  500000.00,  500000.00),  -- 1
('Metro Cash & Carry',      'buying@metro.example.in',       'Bengaluru', '29AAACM7651L1Z3', 1000000.00, 1000000.00),  -- 2
('Vijay Sales Electronics', 'inventory@vijaysales.example.in','Mumbai',   '27AAAFV2150B1ZK',  300000.00,  300000.00),  -- 3
('Spencer''s Retail',       'sourcing@spencers.example.in',  'Kolkata',   '19AAKCS6235N1ZD',  400000.00,  400000.00),  -- 4
('Osia Hypermart',          'purchase@osia.example.in',      'Ahmedabad', '24AABCO4471P1Z6',  250000.00,  250000.00),  -- 5
('More Retail',             'vendors@moreretail.example.in', 'Bengaluru', '29AAHCM1192R1ZT',  350000.00,  350000.00);  -- 6

INSERT INTO Products (supplier_id, category_id, product_name, sku, unit, base_unit_price, stock_quantity, reorder_level) VALUES
(3, 1, 'Havells Spark 1200mm Ceiling Fan',          'HVL-FAN-1200',  'piece',  2500.00, 1500, 200),  -- 1
(2, 2, 'Tata Salt Vacuum Evaporated 50 kg',         'TATA-SALT-50',  'bag',    1200.00, 5000, 500),  -- 2
(2, 3, 'Tata Tea Premium 1 kg (carton of 12)',      'TATA-TEA-12',   'carton', 4800.00,  800, 100),  -- 3
(3, 1, 'Havells LED Batten 20W',                    'HVL-LED-20W',   'piece',   350.00, 4000, 400),  -- 4
(1, 2, 'Independence Chakki Atta 10 kg',            'REL-ATTA-10',   'bag',     420.00, 3000, 300),  -- 5
(1, 3, 'Campa Cola 2 L (crate of 9)',               'REL-CAMPA-9',   'crate',   540.00, 1200, 150),  -- 6
(4, 4, 'Dabur Red Toothpaste 200 g (carton of 24)', 'DAB-RED-24',    'carton', 2640.00,  600,  80),  -- 7
(5, 5, 'Bajaj Rex 750W Mixer Grinder',              'BAJ-MIX-750',   'piece',  3200.00,  300,  60),  -- 8
(6, 2, 'Fortune Sunflower Oil 15 L',                'AWL-SUN-15L',   'tin',    2150.00,  150, 100),  -- 9
(4, 4, 'Dabur Honey 1 kg (carton of 6)',            'DAB-HONEY-6',   'carton', 1800.00,   70,  50),  -- 10
(3, 5, 'Havells Instanio 3 L Water Heater',         'HVL-WH-3L',     'piece',  4100.00,    0,  40);  -- 11

INSERT INTO Price_Tiers (product_id, min_quantity, max_quantity, discounted_unit_price) VALUES
(1,  1,    9, 2500.00), (1, 10,   49, 2200.00), (1,  50, NULL, 1950.00),
(2,  1,   19, 1200.00), (2, 20, NULL, 1050.00),
(3,  1,    9, 4800.00), (3, 10,   49, 4500.00), (3,  50, NULL, 4200.00),
(4,  1,   49,  350.00), (4, 50,  199,  310.00), (4, 200, NULL,  280.00),
(5,  1,   49,  420.00), (5, 50,  199,  395.00), (5, 200, NULL,  370.00),
(6,  1,   24,  540.00), (6, 25, NULL,  495.00),
(7,  1,    9, 2640.00), (7, 10,   49, 2450.00), (7,  50, NULL, 2300.00),
(8,  1,    4, 3200.00), (8,  5,   19, 2950.00), (8,  20, NULL, 2750.00),
(9,  1,    9, 2150.00), (9, 10, NULL, 2020.00),
(10, 1,    9, 1800.00), (10,10, NULL, 1680.00),
(11, 1,    9, 4100.00), (11,10, NULL, 3800.00);

-- Historical orders (IDs 1 to 14), placed through the real procedure
CALL PlaceOrder(1, '[{"product_id":1,"qty":50},{"product_id":5,"qty":100}]');
CALL PlaceOrder(2, '[{"product_id":2,"qty":40},{"product_id":3,"qty":20},{"product_id":9,"qty":30}]');
CALL PlaceOrder(3, '[{"product_id":1,"qty":20},{"product_id":8,"qty":10},{"product_id":4,"qty":200}]');
CALL PlaceOrder(4, '[{"product_id":3,"qty":10},{"product_id":7,"qty":12}]');
CALL PlaceOrder(5, '[{"product_id":5,"qty":200},{"product_id":2,"qty":20}]');
CALL PlaceOrder(6, '[{"product_id":6,"qty":30},{"product_id":10,"qty":10},{"product_id":9,"qty":10}]');
CALL PlaceOrder(2, '[{"product_id":1,"qty":100},{"product_id":4,"qty":300}]');
CALL PlaceOrder(1, '[{"product_id":3,"qty":15},{"product_id":6,"qty":50}]');
CALL PlaceOrder(3, '[{"product_id":8,"qty":25}]');
CALL PlaceOrder(5, '[{"product_id":9,"qty":25},{"product_id":10,"qty":20}]');
CALL PlaceOrder(6, '[{"product_id":7,"qty":20}]');
CALL PlaceOrder(4, '[{"product_id":2,"qty":60},{"product_id":5,"qty":50}]');
CALL PlaceOrder(2, '[{"product_id":6,"qty":100},{"product_id":3,"qty":50}]');
CALL PlaceOrder(1, '[{"product_id":1,"qty":10}]');

-- Payments (full and partial)
CALL RecordPayment(1,  137000.00, 'NEFT',   'NEFT-DM-240519');
CALL RecordPayment(2,  192600.00, 'RTGS',   'RTGS-MT-240602');
CALL RecordPayment(3,   80000.00, 'NEFT',   'NEFT-VS-240618');
CALL RecordPayment(4,   74400.00, 'UPI',    'UPI-SP-240705');
CALL RecordPayment(5,   95000.00, 'Cheque', 'CHQ-004512');
CALL RecordPayment(6,   30000.00, 'UPI',    'UPI-MR-240809');
CALL RecordPayment(7,  279000.00, 'RTGS',   'RTGS-MT-240824');
CALL RecordPayment(8,   50000.00, 'NEFT',   'NEFT-DM-240911');
CALL RecordPayment(10,  84100.00, 'RTGS',   'RTGS-OS-241003');

-- One cancelled order, and dispatched orders marked fulfilled
CALL CancelOrder(11);
CALL FulfillOrder(1);  CALL FulfillOrder(2);  CALL FulfillOrder(3);
CALL FulfillOrder(4);  CALL FulfillOrder(5);  CALL FulfillOrder(6);
CALL FulfillOrder(7);  CALL FulfillOrder(8);  CALL FulfillOrder(10);

-- Spread the history over six months so monthly reports look realistic
UPDATE Purchase_Orders SET order_date = CASE order_id
    WHEN 1  THEN '2026-05-06 10:15:00' WHEN 2  THEN '2026-05-18 12:40:00'
    WHEN 3  THEN '2026-06-03 11:05:00' WHEN 4  THEN '2026-06-21 16:20:00'
    WHEN 5  THEN '2026-07-08 09:50:00' WHEN 6  THEN '2026-07-26 14:30:00'
    WHEN 7  THEN '2026-08-09 10:00:00' WHEN 8  THEN '2026-08-27 15:45:00'
    WHEN 9  THEN '2026-09-05 11:30:00' WHEN 10 THEN '2026-09-19 13:10:00'
    WHEN 11 THEN '2026-09-28 17:25:00' WHEN 12 THEN '2026-10-07 10:35:00'
    WHEN 13 THEN '2026-10-15 12:00:00' WHEN 14 THEN '2026-10-22 09:20:00'
END
WHERE order_id BETWEEN 1 AND 14;

UPDATE Payments p
JOIN Purchase_Orders o ON o.order_id = p.order_id
SET p.paid_at = DATE_ADD(o.order_date, INTERVAL 14 DAY);

UPDATE Stock_Ledger l
JOIN Purchase_Orders o
  ON l.reason = CONCAT('Sale - Order #', o.order_id)
  OR l.reason = CONCAT('Cancellation - Order #', o.order_id)
SET l.changed_at = CASE WHEN l.reason LIKE 'Sale%' THEN o.order_date
                        ELSE DATE_ADD(o.order_date, INTERVAL 1 DAY) END;

UPDATE Stock_Ledger SET changed_at = '2026-05-01 09:00:00' WHERE reason = 'Opening stock';


-- ---------------------------------------------------------------------
-- 8. REPORT QUERIES (run these one by one during the viva)
-- ---------------------------------------------------------------------

-- R1. Multi-table JOIN: full order detail (5 tables)
SELECT o.order_id, o.order_date, b.company_name AS buyer, p.product_name,
       s.company_name AS supplier, i.quantity, i.applied_unit_price, i.subtotal
FROM Purchase_Orders o
JOIN Wholesale_Buyers b ON b.buyer_id    = o.buyer_id
JOIN Order_Items      i ON i.order_id    = o.order_id
JOIN Products         p ON p.product_id  = i.product_id
JOIN Suppliers        s ON s.supplier_id = p.supplier_id
ORDER BY o.order_id;

-- R2. GROUP BY + HAVING: buyers who bought more than Rs. 2 lakh
SELECT b.company_name, COUNT(*) AS orders, SUM(o.total_amount) AS total_spend
FROM Purchase_Orders o
JOIN Wholesale_Buyers b ON b.buyer_id = o.buyer_id
WHERE o.status <> 'Cancelled'
GROUP BY b.buyer_id, b.company_name
HAVING SUM(o.total_amount) > 200000
ORDER BY total_spend DESC;

-- R3. Subquery with NOT EXISTS: products that were never ordered
SELECT p.product_id, p.product_name, p.stock_quantity
FROM Products p
WHERE NOT EXISTS (SELECT 1 FROM Order_Items i WHERE i.product_id = p.product_id);

-- R4. Window function: rank suppliers by revenue
SELECT company_name, revenue,
       RANK() OVER (ORDER BY revenue DESC) AS sales_rank
FROM vw_supplier_sales;

-- R5. Monthly revenue trend
SELECT DATE_FORMAT(order_date, '%Y-%m') AS month,
       COUNT(*) AS orders, SUM(total_amount) AS revenue
FROM Purchase_Orders
WHERE status <> 'Cancelled'
GROUP BY DATE_FORMAT(order_date, '%Y-%m')
ORDER BY month;

-- R6. Savings that tier pricing gave each buyer compared with base price
SELECT b.company_name,
       SUM((p.base_unit_price - i.applied_unit_price) * i.quantity) AS tier_savings
FROM Order_Items i
JOIN Products         p ON p.product_id = i.product_id
JOIN Purchase_Orders  o ON o.order_id   = i.order_id
JOIN Wholesale_Buyers b ON b.buyer_id   = o.buyer_id
WHERE o.status <> 'Cancelled'
GROUP BY b.buyer_id, b.company_name
ORDER BY tier_savings DESC;

-- R7. Integrity proof: credit used must equal the unpaid amount of the
--     buyer's orders. The mismatch column should be 0 for every buyer.
SELECT c.company_name, c.credit_used,
       COALESCE(SUM(s.outstanding), 0)                 AS unpaid_orders,
       c.credit_used - COALESCE(SUM(s.outstanding), 0) AS mismatch
FROM vw_buyer_credit c
LEFT JOIN vw_order_summary s ON s.buyer_id = c.buyer_id
GROUP BY c.buyer_id, c.company_name, c.credit_used;


-- ---------------------------------------------------------------------
-- 9. ACCESS CONTROL (DCL)
-- trinetra_app    : used by the website. Can read data and EXECUTE the
--                   procedures, but cannot INSERT/UPDATE/DELETE tables
--                   directly. Every write must pass the business rules
--                   inside the procedures. (Procedures run with their
--                   creator's rights: SQL SECURITY DEFINER.)
-- trinetra_viewer : read-only, and only the views.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS trinetra_app_role;
CREATE ROLE IF NOT EXISTS trinetra_viewer_role;

GRANT SELECT, EXECUTE ON trinetra_db.* TO trinetra_app_role;

GRANT SELECT ON trinetra_db.vw_product_catalog TO trinetra_viewer_role;
GRANT SELECT ON trinetra_db.vw_buyer_credit    TO trinetra_viewer_role;
GRANT SELECT ON trinetra_db.vw_order_summary   TO trinetra_viewer_role;
GRANT SELECT ON trinetra_db.vw_supplier_sales  TO trinetra_viewer_role;
GRANT SELECT ON trinetra_db.vw_low_stock       TO trinetra_viewer_role;

-- The website runs on a different server, so the users must accept
-- remote connections ('%'). The cloud provider requires SSL for them.
CREATE USER IF NOT EXISTS 'trinetra_app'@'%'    IDENTIFIED BY 'Trinetra@2026';
CREATE USER IF NOT EXISTS 'trinetra_viewer'@'%' IDENTIFIED BY 'Viewer@2026';

GRANT trinetra_app_role    TO 'trinetra_app'@'%';
GRANT trinetra_viewer_role TO 'trinetra_viewer'@'%';

-- The role switches on automatically when the user logs in
SET DEFAULT ROLE trinetra_app_role    TO 'trinetra_app'@'%';
SET DEFAULT ROLE trinetra_viewer_role TO 'trinetra_viewer'@'%';

FLUSH PRIVILEGES;

-- Demo of REVOKE (try it, then re-grant):
--   REVOKE EXECUTE ON trinetra_db.* FROM trinetra_app_role;
--   GRANT  EXECUTE ON trinetra_db.* TO   trinetra_app_role;

-- =====================================================================
-- End of script
-- =====================================================================
