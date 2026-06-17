-- NIVELL 1:

-- Crear dataset Silver
CREATE SCHEMA sprint3_silver
OPTIONS (location = 'EU');

-- Crear taula externa transactions_raw
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.transactions_raw
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/ERP/transactions.csv'],
  field_delimiter = ';',
  skip_leading_rows = 1
);

-- Veure dades de transactions_raw per confirmar que funciona
SELECT *
FROM sprint3_bronze.transactions_raw
LIMIT 5;

-- Crear taula externa companies_raw sense esquema per veure columnes
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.companies_raw
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/ERP/companies.csv'],
  skip_leading_rows = 1
);

-- Veure primeres files de companies_raw per identificar columnes
SELECT *
FROM sprint3_bronze.companies_raw
LIMIT 3;

-- Crear taula externa companies_raw amb esquema manual (tot STRING)
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.companies_raw (
  id STRING,
  company_name STRING,
  phone STRING,
  email STRING,
  country STRING,
  website STRING
)
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/ERP/companies.csv'],
  skip_leading_rows = 1
);

-- Crear taula externa american_users_raw
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.american_users_raw
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/CRM/american_users.csv'],
  skip_leading_rows = 1
);

-- Crear taula externa european_users_raw
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.european_users_raw
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/CRM/european_users.csv'],
  skip_leading_rows = 1
);

-- Crear taula externa credit_cards_raw
CREATE OR REPLACE EXTERNAL TABLE sprint3_bronze.credit_cards_raw
OPTIONS (
  format = 'CSV',
  uris = ['gs://bootcamp-data-analytics-public/CRM/credit_cards.csv'],
  skip_leading_rows = 1
);

-- Crear la taula transactions_raw_native amb Gemini
CREATE OR REPLACE TABLE `sprint3-analytics-julia-valls`.sprint3_bronze.transactions_raw_native
AS
SELECT * FROM `sprint3-analytics-julia-valls`.sprint3_bronze.transactions_raw;

-- Consulta sobre taula EXTERNA per veure cost
SELECT id
FROM sprint3_bronze.transactions_raw;

-- Consulta sobre taula NATIVA per veure cost
SELECT id
FROM sprint3_bronze.transactions_raw_native;

-- Comprovar si LIMIT redueix el cost en una taula externa
SELECT *
FROM sprint3_bronze.transactions_raw_native
LIMIT 10;

-- Veure format del camp timestamp a transactions_raw
SELECT timestamp
FROM sprint3_bronze.transactions_raw
LIMIT 5;

-- Top 5 dies amb més ingressos l'any 2021
SELECT 
  DATE(timestamp) AS date,
  ROUND(SUM(SAFE_CAST(amount AS FLOAT64)), 2) AS total_amount
FROM sprint3_bronze.transactions_raw
WHERE EXTRACT(YEAR FROM timestamp) = 2021
GROUP BY DATE(timestamp)
ORDER BY total_amount DESC
LIMIT 5;

-- Nom, país i data de transaccions entre 100 i 200€ en dates específiques
SELECT 
  c.company_name,
  c.country,
  DATE(t.timestamp) AS date
FROM sprint3_bronze.companies_raw c
JOIN sprint3_bronze.transactions_raw t ON c.id = t.business_id
WHERE SAFE_CAST(t.amount AS FLOAT64) BETWEEN 100 AND 200
  AND DATE(t.timestamp) IN (
    DATE '2015-04-29',
    DATE '2018-07-20',
    DATE '2024-03-13'
  );

-- NIVELL 2:

-- Veure contingut de products_raw per comprovar el format de warehouse_id
SELECT warehouse_id
FROM sprint3_bronze.products_raw
LIMIT 5;

-- Crear taula products_clean a la capa Silver
CREATE OR REPLACE TABLE sprint3_silver.products_clean AS
SELECT
  id AS product_id,
  product_name AS name,
  SAFE_CAST(SUBSTR(warehouse_id, 4) AS INT64) AS warehouse_id,
  SAFE_CAST(price AS FLOAT64) AS price,
  weight,
  colour,
  category,
  brand,
  cost,
  launch_date
FROM sprint3_bronze.products_raw;

-- Crear taula transactions_clean a la capa Silver
CREATE OR REPLACE TABLE sprint3_silver.transactions_clean AS
SELECT
  id AS transaction_id,
  card_id,
  business_id,
  timestamp,
  IFNULL(SAFE_CAST(amount AS FLOAT64), 0) AS amount,
  declined,
  ARRAY(SELECT SAFE_CAST(x AS INT64) 
        FROM UNNEST(SPLIT(product_ids, ', ')) AS x) AS product_ids,
  user_id,
  SAFE_CAST(lat AS FLOAT64) AS lat,
  SAFE_CAST(longitude AS FLOAT64) AS longitude
FROM sprint3_bronze.transactions_raw;

-- Crear taula users_combined a la capa Silver unificant usuaris americans i europeus
CREATE OR REPLACE TABLE sprint3_silver.users_combined AS
SELECT
  id AS user_id,
  name,
  surname,
  phone,
  email,
  birth_date,
  country,
  city,
  postal_code,
  address,
  'American' AS origin
FROM sprint3_bronze.american_users_raw

UNION ALL

SELECT
  id AS user_id,
  name,
  surname,
  phone,
  email,
  birth_date,
  country,
  city,
  postal_code,
  address,
  'European' AS origin
FROM sprint3_bronze.european_users_raw;

-- Crear taula companies_clean a la capa Silver
CREATE OR REPLACE TABLE sprint3_silver.companies_clean AS
SELECT
  id AS company_id,
  company_name,
  phone,
  email,
  country,
  website
FROM sprint3_bronze.companies_raw;

-- Crear taula credit_cards_clean a la capa Silver
CREATE OR REPLACE TABLE sprint3_silver.credit_cards_clean AS
SELECT
  id AS card_id,
  user_id,
  iban,
  pan,
  pin,
  cvv,
  track1,
  track2,
  expiring_date
FROM sprint3_bronze.credit_cards_raw;

-- Crear vista v_marketing_kpis a la capa Gold
CREATE OR REPLACE VIEW sprint3_gold.v_marketing_kpis AS
SELECT
  c.company_id,
  c.company_name,
  c.phone,
  c.country,
  ROUND(AVG(t.amount), 2) AS avg_amount,
  CASE WHEN AVG(t.amount) > 260 THEN 'Premium' ELSE 'Standard' END AS client_tier
FROM sprint3_silver.companies_clean c
JOIN sprint3_silver.transactions_clean t ON c.company_id = t.business_id
GROUP BY c.company_id, c.company_name, c.phone, c.country;

-- Consulta sobre la vista v_marketing_kpis ordenada per client_tier i avg_amount
SELECT *
FROM sprint3_gold.v_marketing_kpis
ORDER BY client_tier, avg_amount DESC;

-- Crear taula product_sales_ranking a la capa Gold
CREATE OR REPLACE TABLE sprint3_gold.product_sales_ranking AS
WITH transactions_flat AS (
  SELECT product_id
  FROM sprint3_silver.transactions_clean,
  UNNEST(product_ids) AS product_id
)
SELECT
  p.product_id,
  p.name,
  p.price,
  p.colour,
  COUNT(tf.product_id) AS total_sold
FROM sprint3_silver.products_clean p
LEFT JOIN transactions_flat tf ON p.product_id = tf.product_id
GROUP BY p.product_id, p.name, p.price, p.colour
ORDER BY total_sold DESC;

-- Consulta sobre product_sales_ranking per exportar
SELECT *
FROM sprint3_gold.product_sales_ranking;