-- =====================================================================
-- 02_analysis.sql  |  Swiggy restaurant market analysis
-- Dialect: SQLite 3.25+. Run 01_clean.sql first.
-- Each query is tagged (-- @name / @title / @chart / @insight) so that
-- scripts/build.py can save its output to results/ and chart it on the dashboard.
-- =====================================================================


-- @name: overview
-- @section: Market at a glance
-- @title: Headline numbers
-- @chart: kpi money=median_cost_for_two
-- @insight: 148,442 clean listings across 551 cities. Only 41% have enough reviews to show a rating, so every rating comparison below is based on that rated subset.
WITH ordered AS (
    SELECT cost_for_two,
           ROW_NUMBER() OVER (ORDER BY cost_for_two) AS rn,
           COUNT(*)     OVER ()                      AS n
    FROM restaurants
    WHERE cost_for_two IS NOT NULL
),
chains AS (
    SELECT brand
    FROM restaurants
    GROUP BY brand
    HAVING COUNT(*) >= 10
)
SELECT
    (SELECT COUNT(*) FROM restaurants)                                   AS restaurants,
    (SELECT COUNT(DISTINCT city) FROM restaurants)                       AS cities,
    (SELECT ROUND(100.0 * COUNT(rating) / COUNT(*), 1) FROM restaurants) AS rated_pct,
    (SELECT ROUND(AVG(rating), 2) FROM restaurants)                      AS avg_rating,
    (SELECT cost_for_two FROM ordered WHERE rn = (n + 1) / 2)            AS median_cost_for_two,
    (SELECT COUNT(*) FROM chains)                                        AS brands_with_10_plus_outlets;


-- @name: top_cities
-- @section: Where the supply is
-- @title: Top 15 cities by restaurant listings
-- @chart: hbar x=city y=restaurants
-- @insight: Bangalore and Delhi lead with about 14,000 to 15,000 listings each. Pune, with 12,434, has twice as many listings as Mumbai.
SELECT city, COUNT(*) AS restaurants
FROM restaurants
GROUP BY city
ORDER BY restaurants DESC
LIMIT 15;


-- @name: city_concentration
-- @section: Where the supply is
-- @title: Cumulative share of listings held by the top 25 cities
-- @chart: line x=city_rank y=cumulative_pct zero=yes
-- @insight: Seven cities hold half of all listings, and the top 25 hold 71%. The remaining 526 cities share the other 29%.
WITH by_city AS (
    SELECT city, COUNT(*) AS restaurants
    FROM restaurants
    GROUP BY city
),
ranked AS (
    SELECT city, restaurants,
           ROW_NUMBER() OVER (ORDER BY restaurants DESC) AS city_rank,
           SUM(restaurants) OVER (ORDER BY restaurants DESC
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total,
           SUM(restaurants) OVER () AS total
    FROM by_city
)
SELECT city_rank, city, restaurants,
       ROUND(100.0 * running_total / total, 1) AS cumulative_pct
FROM ranked
WHERE city_rank <= 25
ORDER BY city_rank;


-- @name: rated_share_by_city
-- @section: Where the supply is
-- @title: Share of listings with enough reviews to carry a rating (top 15 cities)
-- @chart: hbar x=city y=rated_pct
-- @insight: Apart from Bikaner (51%), no large city has more than half its listings rated. Chennai and Hyderabad have the deepest review base; in Gurgaon, Lucknow and Nagpur fewer than 30% of outlets have a rating yet.
SELECT city,
       COUNT(*)                                   AS restaurants,
       COUNT(rating)                              AS rated_restaurants,
       ROUND(100.0 * COUNT(rating) / COUNT(*), 1) AS rated_pct
FROM restaurants
WHERE city IN (SELECT city FROM restaurants GROUP BY city ORDER BY COUNT(*) DESC LIMIT 15)
GROUP BY city
ORDER BY rated_pct DESC;


-- @name: top_areas
-- @section: Where the supply is
-- @title: Busiest delivery neighbourhoods
-- @chart: hbar x=area_city y=restaurants
-- @insight: Indirapuram (Delhi NCR) is the densest delivery neighbourhood with 1,279 listings. Kukatpally in Hyderabad has heavy supply but the weakest rating in this list, 3.58.
SELECT area || ', ' || city AS area_city,
       COUNT(*)            AS restaurants,
       ROUND(AVG(rating), 2) AS avg_rating
FROM restaurants
WHERE area IS NOT NULL
GROUP BY area, city
ORDER BY restaurants DESC
LIMIT 12;


-- @name: top_cuisines
-- @section: What India orders
-- @title: Most listed cuisines (a restaurant counts once per cuisine tag)
-- @chart: hbar x=cuisine y=restaurants
-- @insight: Chinese is tagged on 24.6% of listings, ahead of North Indian at 21.9%. Indo-Chinese is the closest thing India has to a default delivery menu.
SELECT rc.cuisine,
       COUNT(*)                                                   AS restaurants,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM restaurants), 1) AS share_of_listings_pct
FROM restaurant_cuisines rc
GROUP BY rc.cuisine
ORDER BY restaurants DESC
LIMIT 15;


-- @name: cuisine_rating_gap
-- @section: What India orders
-- @title: Rating above or below the national average, by cuisine (cuisines with 1,000+ rated outlets)
-- @chart: hbar x=cuisine y=rating_gap
-- @insight: Ice cream, healthy food and desserts rate 0.2 to 0.4 points above the national average of 3.89. The most crowded categories, Chinese, North Indian and Biryani, all sit below it.
WITH national AS (SELECT AVG(rating) AS avg_rating FROM restaurants)
SELECT rc.cuisine,
       COUNT(r.rating)                               AS rated_restaurants,
       ROUND(AVG(r.rating), 2)                       AS avg_rating,
       ROUND(AVG(r.rating) - national.avg_rating, 2) AS rating_gap
FROM restaurant_cuisines rc
JOIN restaurants r ON r.restaurant_id = rc.restaurant_id
CROSS JOIN national
GROUP BY rc.cuisine
HAVING COUNT(r.rating) >= 1000
ORDER BY rating_gap DESC;


-- @name: cuisine_price
-- @section: What India orders
-- @title: Average cost for two by cuisine (top 15 cuisines by listings)
-- @chart: hbar x=cuisine y=avg_cost_for_two money=avg_cost_for_two
-- @insight: Continental (₹394) and Italian (₹352) are the most expensive cuisines for two. Snacks, South Indian and ice cream average under ₹250.
SELECT rc.cuisine,
       COUNT(*)                       AS restaurants,
       ROUND(AVG(r.cost_for_two), 0)  AS avg_cost_for_two
FROM restaurant_cuisines rc
JOIN restaurants r ON r.restaurant_id = rc.restaurant_id
WHERE rc.cuisine IN (SELECT cuisine FROM restaurant_cuisines GROUP BY cuisine ORDER BY COUNT(*) DESC LIMIT 15)
GROUP BY rc.cuisine
ORDER BY avg_cost_for_two DESC;


-- @name: price_band_mix
-- @section: Price and quality
-- @title: Restaurants by price band (cost for two)
-- @chart: bar x=price_band y=restaurants
-- @insight: Two in three listings charge ₹200 to ₹399 for two. Fewer than 5% charge ₹600 or more.
SELECT
    CASE
        WHEN cost_for_two < 200  THEN 'Under ₹200'
        WHEN cost_for_two < 400  THEN '₹200-399'
        WHEN cost_for_two < 600  THEN '₹400-599'
        WHEN cost_for_two < 1000 THEN '₹600-999'
        ELSE                          '₹1,000+'
    END                                        AS price_band,
    COUNT(*)                                   AS restaurants,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct,
    ROUND(AVG(rating), 2)                      AS avg_rating,
    ROUND(100.0 * COUNT(rating) / COUNT(*), 1) AS rated_pct
FROM restaurants
WHERE cost_for_two IS NOT NULL
GROUP BY price_band
ORDER BY MIN(cost_for_two);


-- @name: price_band_quality
-- @section: Price and quality
-- @title: Rating above or below the national average, by price band
-- @chart: bar x=price_band y=rating_gap
-- @insight: Ratings rise with price: outlets charging ₹1,000+ rate 0.27 above average, while the two cheapest bands sit at or just below it.
WITH national AS (SELECT AVG(rating) AS avg_rating FROM restaurants)
SELECT
    CASE
        WHEN cost_for_two < 200  THEN 'Under ₹200'
        WHEN cost_for_two < 400  THEN '₹200-399'
        WHEN cost_for_two < 600  THEN '₹400-599'
        WHEN cost_for_two < 1000 THEN '₹600-999'
        ELSE                          '₹1,000+'
    END                     AS price_band,
    COUNT(rating)                              AS rated_restaurants,
    ROUND(AVG(rating), 2)                      AS avg_rating,
    ROUND(AVG(rating) - national.avg_rating, 2) AS rating_gap
FROM restaurants
CROSS JOIN national
WHERE cost_for_two IS NOT NULL
GROUP BY price_band
ORDER BY MIN(cost_for_two);


-- @name: reviews_vs_rating
-- @section: Price and quality
-- @title: Rating above or below the national average, by number of reviews
-- @chart: bar x=review_band y=rating_gap
-- @insight: More-reviewed outlets rate higher. Outlets with 1,000+ reviews sit 0.16 above average; those with only 20+ reviews sit 0.14 below.
WITH national AS (SELECT AVG(rating) AS avg_rating FROM restaurants)
SELECT
    CASE min_reviews
        WHEN 20    THEN '20+'
        WHEN 50    THEN '50+'
        WHEN 100   THEN '100+'
        WHEN 500   THEN '500+'
        WHEN 1000  THEN '1K+'
        ELSE            '5K+'
    END                    AS review_band,
    COUNT(*)                                   AS restaurants,
    ROUND(AVG(rating), 2)                      AS avg_rating,
    ROUND(AVG(rating) - national.avg_rating, 2) AS rating_gap
FROM restaurants
CROSS JOIN national
WHERE rating IS NOT NULL
GROUP BY CASE WHEN min_reviews >= 5000 THEN 5000 ELSE min_reviews END
ORDER BY MIN(min_reviews);


-- @name: city_value
-- @section: Price and quality
-- @title: City scorecard: rating and price ranks (cities with 500+ rated outlets)
-- @chart: table money=avg_cost_for_two
-- @insight: Surat and Coimbatore offer the best mix of high ratings and low prices. Mumbai rates highest of all (4.08) but ranks 17th of 18 on affordability.
WITH city_stats AS (
    SELECT city,
           COUNT(*)                      AS restaurants,
           COUNT(rating)                 AS rated_restaurants,
           ROUND(AVG(rating), 2)         AS avg_rating,
           ROUND(AVG(cost_for_two), 0)   AS avg_cost_for_two
    FROM restaurants
    GROUP BY city
    HAVING COUNT(rating) >= 500
)
SELECT city, restaurants, avg_rating, avg_cost_for_two,
       RANK() OVER (ORDER BY avg_rating DESC)      AS rating_rank,
       RANK() OVER (ORDER BY avg_cost_for_two ASC) AS affordability_rank,
       RANK() OVER (ORDER BY avg_rating DESC) + RANK() OVER (ORDER BY avg_cost_for_two ASC) AS value_score
FROM city_stats
ORDER BY value_score, rating_rank;


-- @name: top_chains
-- @section: Chains
-- @title: Largest chains by outlets listed
-- @chart: hbar x=brand y=outlets
-- @insight: Domino's is the largest chain with 442 outlets in 246 cities, and it rates 4.21 against Pizza Hut's 3.64.
SELECT brand,
       COUNT(*)              AS outlets,
       COUNT(DISTINCT city)  AS cities,
       ROUND(AVG(rating), 2) AS avg_rating
FROM restaurants
GROUP BY brand
ORDER BY outlets DESC
LIMIT 15;


-- @name: chain_quality
-- @section: Chains
-- @title: How the big chains rate (brands with 50+ rated outlets)
-- @chart: table
-- @insight: Ice cream and dessert brands take the top of the chain table. Among meal chains, Domino's (4.21), McDonald's (4.19) and Burger King (4.12) rate best.
WITH brand AS (
    SELECT brand,
           COUNT(*)              AS outlets,
           COUNT(rating)         AS rated_outlets,
           ROUND(AVG(rating), 2) AS avg_rating,
           ROUND(MIN(rating), 1) AS worst_outlet,
           ROUND(MAX(rating), 1) AS best_outlet
    FROM restaurants
    GROUP BY brand
    HAVING COUNT(rating) >= 50
)
SELECT DENSE_RANK() OVER (ORDER BY avg_rating DESC) AS rank,
       brand, outlets, rated_outlets, avg_rating, worst_outlet, best_outlet
FROM brand
ORDER BY rank, outlets DESC
LIMIT 20;


-- @name: city_leaders
-- @section: Chains
-- @title: Biggest chain in each of the top 10 cities
-- @chart: table
-- @insight: Domino's is the biggest chain in Chennai, Pune and Hyderabad, but local brands lead elsewhere: Five Star Chicken in Bangalore, Wow! Momo in Kolkata and Lucknow, Tea Post in Ahmedabad.
WITH top_cities AS (
    SELECT city FROM restaurants GROUP BY city ORDER BY COUNT(*) DESC LIMIT 10
),
brand_city AS (
    SELECT r.city, r.brand, COUNT(*) AS outlets,
           ROW_NUMBER() OVER (PARTITION BY r.city ORDER BY COUNT(*) DESC) AS rn
    FROM restaurants r
    JOIN top_cities t ON t.city = r.city
    GROUP BY r.city, r.brand
)
SELECT city, brand AS biggest_chain, outlets
FROM brand_city
WHERE rn = 1
ORDER BY outlets DESC;


-- @name: data_quality
-- @section: Data quality
-- @title: What the cleaning step found and fixed
-- @chart: table
-- @insight: The raw city field mixes neighbourhood and city, so a naive GROUP BY city ranks Bikaner first. Splitting it moves Bangalore and Delhi to the top and cuts 821 "cities" to 551.
SELECT check_name, rows_affected, action
FROM data_quality_log;
