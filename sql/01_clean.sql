-- =====================================================================
-- 01_clean.sql  |  Swiggy restaurant listings: profiling and cleaning
-- Dialect: SQLite 3.25+  (also runs in DB Browser for SQLite)
-- Input : swiggy_raw  (the Kaggle CSV loaded as-is, every column TEXT)
-- Output: restaurants, restaurant_cuisines, data_quality_log
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Profile the raw file before changing anything
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS data_quality_log;
CREATE TABLE data_quality_log (check_name TEXT, rows_affected INTEGER, action TEXT);

INSERT INTO data_quality_log
SELECT 'Raw rows loaded', COUNT(*), 'none' FROM swiggy_raw;

-- 86 rows are empty placeholders: every field holds the text 'NA'
INSERT INTO data_quality_log
SELECT 'Empty row (name and all fields = ''NA'')', COUNT(*), 'dropped'
FROM swiggy_raw WHERE name IS NULL OR TRIM(name) IN ('', 'NA');

-- The same outlet listed twice (same name, area and address)
INSERT INTO data_quality_log
SELECT 'Duplicate listing (name + area + address)', COUNT(*) - COUNT(DISTINCT LOWER(name) || '|' || city || '|' || COALESCE(address, '')), 'kept first id'
FROM swiggy_raw WHERE name IS NOT NULL AND TRIM(name) NOT IN ('', 'NA');

-- '--' means the outlet has too few reviews to show a score
INSERT INTO data_quality_log
SELECT 'Rating shown as --  (too few reviews)', COUNT(*), 'kept, rating set to NULL'
FROM swiggy_raw WHERE rating = '--';

-- The city column is really "area,city" (e.g. 'BTM,Bangalore'); grouping on it
-- splits Bangalore into dozens of neighbourhoods
INSERT INTO data_quality_log
SELECT 'City field holds "area,city"', COUNT(*), 'split into area and city'
FROM swiggy_raw WHERE INSTR(city, ',') > 0;

-- ---------------------------------------------------------------------
-- 2. Build the clean restaurants table
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS restaurants;
CREATE TABLE restaurants AS
WITH dedup AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY LOWER(TRIM(name)), city, COALESCE(address, '')
               ORDER BY CAST(id AS INTEGER)
           ) AS rn
    FROM swiggy_raw
    WHERE name IS NOT NULL AND TRIM(name) NOT IN ('', 'NA')
),
prefix AS (
    -- everything up to and including the LAST comma; a few values carry two
    -- commas, so splitting on the first comma would leave 'New BEL Road,Bangalore' as a city
    SELECT *, RTRIM(city, REPLACE(city, ',', '')) AS head
    FROM dedup
    WHERE rn = 1
),
split AS (
    SELECT *,
           SUBSTR(city, LENGTH(head) + 1)                                   AS city_part,
           CASE WHEN head <> '' THEN SUBSTR(head, 1, LENGTH(head) - 1) END AS area_part
    FROM prefix
)
SELECT
    CAST(id AS INTEGER)                                         AS restaurant_id,
    TRIM(name)                                                  AS restaurant_name,
    TRIM(area_part)                                             AS area,
    CASE WHEN city_part = 'Noida-1' THEN 'Noida'
         ELSE REPLACE(TRIM(city_part), '-', ' ') END            AS city,
    CASE WHEN rating GLOB '[0-9]*' THEN CAST(rating AS REAL) END AS rating,
    rating_count                                                AS rating_count_band,
    -- lower bound of the review-count band: '1K+ ratings' -> 1000
    CASE
        WHEN rating_count = 'Too Few Ratings' THEN 0
        WHEN rating_count LIKE '%K+%'
             THEN CAST(REPLACE(rating_count, 'K+ ratings', '') AS INTEGER) * 1000
        ELSE CAST(REPLACE(rating_count, '+ ratings', '') AS INTEGER)
    END                                                         AS min_reviews,
    CAST(TRIM(REPLACE(REPLACE(cost, '₹', ''), ',', '')) AS INTEGER) AS cost_for_two,
    cuisine,
    lic_no
FROM split;

-- Cost outliers: anything outside Rs 50 to Rs 5,000 for two is a data-entry error
INSERT INTO data_quality_log
SELECT 'Cost for two missing or outside Rs 50-5,000', COUNT(*), 'cost set to NULL'
FROM restaurants
WHERE cost_for_two IS NULL OR cost_for_two < 50 OR cost_for_two > 5000;

UPDATE restaurants
SET cost_for_two = NULL
WHERE cost_for_two < 50 OR cost_for_two > 5000;

INSERT INTO data_quality_log
SELECT 'Clean restaurant rows', COUNT(*), 'final table' FROM restaurants;

-- ---------------------------------------------------------------------
-- 3. One row per restaurant per cuisine tag
--    'Pizzas,Italian' becomes two rows, so cuisine counts are not
--    distorted by every unique combination string
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS restaurant_cuisines;
CREATE TABLE restaurant_cuisines AS
WITH RECURSIVE tags(restaurant_id, tag, rest) AS (
    SELECT restaurant_id, '', cuisine || ','
    FROM restaurants
    WHERE cuisine IS NOT NULL
    UNION ALL
    SELECT restaurant_id,
           TRIM(SUBSTR(rest, 1, INSTR(rest, ',') - 1)),
           SUBSTR(rest, INSTR(rest, ',') + 1)
    FROM tags
    WHERE rest <> ''
)
SELECT DISTINCT restaurant_id, tag AS cuisine
FROM tags
WHERE tag <> '';

CREATE INDEX idx_rc_cuisine ON restaurant_cuisines (cuisine);
CREATE INDEX idx_r_city ON restaurants (city);

-- ---------------------------------------------------------------------
-- 4. One display name per brand
--    'PIZZA HUT', 'Pizza Hut' and 'Pizza hut' are the same chain; use the
--    spelling that appears most often
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS brand_names;
CREATE TABLE brand_names AS
WITH variants AS (
    SELECT LOWER(restaurant_name) AS brand_key,
           restaurant_name,
           ROW_NUMBER() OVER (PARTITION BY LOWER(restaurant_name)
                              ORDER BY COUNT(*) DESC, restaurant_name) AS rn
    FROM restaurants
    GROUP BY LOWER(restaurant_name), restaurant_name
)
SELECT brand_key, restaurant_name AS brand
FROM variants
WHERE rn = 1;

CREATE UNIQUE INDEX idx_brand_key ON brand_names (brand_key);

ALTER TABLE restaurants ADD COLUMN brand TEXT;
UPDATE restaurants
SET brand = (SELECT b.brand FROM brand_names b WHERE b.brand_key = LOWER(restaurants.restaurant_name));
