/* =====================================================================
   LOAN DEFAULT RISK PROJECT  |  File 2 of 2
   More segment analysis, combined risk scorecard, manual-review rule,
   and the final table used by Power BI
   ---------------------------------------------------------------------
   Requires: accepted_stg from File 1 (1,344,989 loans, baseline
   default rate 19.97%, default_flag = 1 for Charged Off / Default).

   PIPELINE:   accepted_stg  ->  loan_scored  ->  Power BI dashboard
   Run the statements in the order they appear in this file.
   ===================================================================== */


/* =====================================================================
   PART A: REMAINING SINGLE-SIGNAL AND CROSS-TAB ANALYSIS
   ===================================================================== */

-- A.1 DEFAULT RATE BY EMPLOYMENT LENGTH
-- emp_length is text, so a CASE maps each label to a number
-- (band_order) to get a sensible sort order (< 1 year ... 10+ years,
-- then Unknown last) instead of alphabetical order.
-- Result: 10+ years is lowest at 18.78%; < 1 year and 1 year are about
-- 20.5%; Unknown (missing, 78,169 loans) is highest at 26.95%.
-- Findings: employment length barely matters among known values, but a
-- missing value is itself a risk signal. That is why NULLs were labelled
-- 'Unknown' in File 1 instead of being deleted.
SELECT 
CASE WHEN EMP_LENGTH = '< 1 year' THEN 1
	WHEN EMP_LENGTH = '1 year' THEN 2
	WHEN EMP_LENGTH = '2 years' THEN 3
	WHEN EMP_LENGTH = '3 years' THEN 4
	WHEN EMP_LENGTH = '4 years' THEN 5
	WHEN EMP_LENGTH = '5 years' THEN 6
	WHEN EMP_LENGTH = '6 years' THEN 7
	WHEN EMP_LENGTH = '7 years' THEN 8
	WHEN EMP_LENGTH = '8 years' THEN 9
	WHEN EMP_LENGTH = '9 years' THEN 10
	WHEN EMP_LENGTH = '10+ years' THEN 11
	ELSE 12
END AS BAND_ORDER,
EMP_LENGTH,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY EMP_LENGTH
ORDER BY BAND_ORDER 



-- A.2 LOAN AMOUNT BAND x TERM (testing for confounding)
-- Overall, default rate rises with loan size (15.49% for <5K up to
-- 24.23% for 30K+). This query splits each loan-size band by term to
-- check whether size is a real driver or just a proxy for term.
-- Result: larger bands contain far more 60-month loans (about 1% of the
-- <5K band, about 47% of the 30K+ band), and 60-month loans default at
-- about twice the 36-month rate in EVERY band (for example 10-20K:
-- 15.78% vs 33.44%). Within 36-month loans the rate is roughly flat.
-- Conclusion: the loan-size pattern is mostly the TERM effect in
-- disguise (confounding). Loan size is used later for EXPOSURE (money
-- at stake), not as a risk predictor.
-- The ELSE 6 / ELSE '0' branches never fire (loans run 500 to 40,000).
-- GROUP BY lists both CASE outputs because every non-aggregated column
-- in the SELECT must be grouped.
SELECT
CASE WHEN LOAN_AMNT <5000 THEN 1
	WHEN LOAN_AMNT < 10000 THEN 2
	WHEN LOAN_AMNT <20000 THEN 3
	WHEN LOAN_AMNT <30000 THEN 4
	WHEN LOAN_AMNT >= 30000 THEN 5
	ELSE 6
END AS BAND_ORDER,
CASE WHEN LOAN_AMNT <5000 THEN '<5K'
	WHEN LOAN_AMNT < 10000 THEN '5-10K'
	WHEN LOAN_AMNT <20000 THEN '10-20K'
	WHEN LOAN_AMNT <30000 THEN '20-30K'
	WHEN LOAN_AMNT >= 30000 THEN '30K+'
	ELSE '0'
END AS LOAN_BAND,
TERM,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY BAND_ORDER, LOAN_BAND, TERM
ORDER BY BAND_ORDER 


-- A.3 DEFAULT RATE BY LENDINGCLUB GRADE (benchmark)
-- grade (A to G) is the lender's own risk rating. It is NOT used as an
-- input to our scorecard (that would just repeat their model); it is
-- used as a yardstick to validate our findings.
-- Result: A 6.04% | B 13.39% | C 22.44% | D 30.39% | E 38.49% |
--         F 45.21% | G 49.92%  (about an 8x gap, no reversals)
-- DISTINCT is redundant here because GROUP BY already returns one row
-- per grade.
SELECT 
DISTINCT GRADE,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY GRADE
ORDER BY GRADE

-- A.4 DEFAULT RATE BY STATE
-- addr_state holds US two-letter postal codes. States with fewer than
-- 1,000 loans are excluded (minimum-volume rule). Sorted alphabetically
-- for lookup; use ORDER BY DEFAULT_RATE_PERC DESC to rank them.
-- Result: highest MS 26.09%, NE 25.16%, AR 24.09%; lowest DC 13.21%,
-- ME 13.85%, VT 13.95%. The extremes are small states; large states
-- are close together (CA 19.61%, TX 19.82%, NY 22.05%), so the state
-- effect is moderate and may partly reflect income or credit mix.
-- DISTINCT is redundant (GROUP BY already gives one row per state).
SELECT 
DISTINCT ADDR_STATE,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY ADDR_STATE
HAVING COUNT(*) >= 1000
ORDER BY ADDR_STATE

-- A.5 DEFAULT RATE BY FICO BAND x TERM
-- Tests whether two signals work independently. The first band is
-- '<700' (it absorbs the 2 loans under 660, which are too few to report).
-- Result (36 months / 60 months):
--   <700     19.29% / 37.30%
--   700-739  12.28% / 27.09%
--   740+      7.08% / 18.86%
-- Finding: both signals stack. The term gap holds at every FICO level
-- and the FICO gap holds within each term, giving a 5.3x spread
-- (7.08% to 37.30%). This is the case for a COMBINED score (Part B).
-- NOTE: the middle band is labelled '<740' in the query below, but it
-- really covers FICO 700-739 (the '700-739' label is used in Part D).
-- It is a label only; the results are not affected.
SELECT 
CASE WHEN FICO_LOW < 700 THEN 1
    WHEN FICO_LOW < 739 THEN 2
    ELSE 3
END AS BAND_ORDER,
CASE WHEN FICO_LOW < 700 THEN '<700'
    WHEN FICO_LOW < 739 THEN '<740'
    ELSE '740+'
END AS FICO_BAND,
TERM,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY FICO_BAND, BAND_ORDER, TERM
ORDER BY BAND_ORDER 


/* =====================================================================
   PART B: RISK SCORECARD AND TIERS
   Each loan earns points for three risk factors, and the points add up
   (score 0 = safest, 6 = riskiest):
     FICO : 740+ = 0 | 700-739 = 1 | below 700 = 2
     DTI  : under 20 = 0 | 20-29.99 = 1 | 30+ = 2
            (missing DTI = 1, a neutral middle value, so the sum does
             not become NULL; only 548 loans are affected)
     Term : 36 months = 0 | 60 months = 2
   Score by score default rate (calculated from the run):
     0: 6.20% | 1: 10.24% | 2: 16.18% | 3: 22.05% | 4: 30.34% |
     5: 39.95% | 6: 48.78%   (a 7.9x spread, rising at every step,
     close to LendingClub's own A-G grade spread of 8.3x)
   Limitation: the factors and cut-offs were chosen after looking at
   this same data, so performance on new applications may be lower. A
   stronger version would build the score on earlier years and test it
   on later years.
   ===================================================================== */

-- B.1 GROUP SCORES INTO THREE TIERS
-- The inner query scores every loan; the outer query groups by tier.
-- The subquery is needed because a column calculated in the SELECT
-- cannot be grouped in the same query level.
-- Execution order: inner SELECT (score per loan) -> outer GROUP BY ->
-- aggregates -> ORDER BY.
-- Result:  Low    (score 0-1)  276,454 loans   9.06%
--          Medium (score 2-3)  767,401 loans  18.29%
--          High   (score 4-6)  301,134 loans  34.25%
-- NOTE: the subquery has no alias. This works on PostgreSQL 16 and
-- later; on older versions add an alias, e.g. ") t".
SELECT
	case when risk_score between 0 and 1 then 'Low'
		when risk_score between 2 and 3 then 'Medium'
		else 'High'
	end as review_queue,
	COUNT(*)                          AS total_loans,
    SUM(default_flag)                 AS default_loans,
    ROUND(100 * AVG(default_flag), 2) AS default_rate_pct
FROM (
    SELECT
		default_flag,
        -- FICO points: lower score = more risk
        (CASE WHEN fico_low < 700 THEN 2
              WHEN fico_low < 740 THEN 1
              ELSE 0 END)
        -- DTI points: higher ratio = more risk (NULL DTI gets 1 point as a middle value)
        + (CASE WHEN dti IS NULL THEN 1
                WHEN dti < 20 THEN 0
                WHEN dti < 30 THEN 1
                ELSE 2 END)
        -- Term points: 60 months = more risk
        + (CASE WHEN term = '60 months' THEN 2 ELSE 0 END)
        AS risk_score
    FROM accepted_stg
) 
GROUP BY review_queue
ORDER BY default_rate_pct;



/* =====================================================================
   PART C: THE MANUAL-REVIEW RULE
   The Medium tier is the grey zone, but at 57% of all loans it is far
   too large to review by hand. Narrowing it by loan size (exposure,
   i.e. money at stake) gives a workable queue.
   ===================================================================== */

-- C.1 TIER x LOAN-AMOUNT BAND, with total loan money in each group
-- total_loan_amount_mn is in millions of dollars.
-- Medium tier results:
--   <10K    315,503 loans  17.71%  $1,876.1M
--   10-20K  283,701 loans  18.10%  $3,795.0M
--   20K+    168,197 loans  19.68%  $4,423.3M
-- RULE: Medium tier AND loan of 20K or more -> manual review.
--   168,197 applications (12.5% of the book, 22% of the Medium tier),
--   holding about 44% of Medium-tier loan value, with a default rate
--   (19.68%) close to the 19.97% average, i.e. a true grey zone.
-- Low tier: approve. High tier: decline or senior sign-off.
-- Note: inside the Medium tier, default rate rises only slightly with
-- loan size, so the 20K cut-off selects for EXPOSURE, not extra risk.
SELECT
    CASE WHEN risk_score BETWEEN 0 AND 1 THEN 'Low'
         WHEN risk_score BETWEEN 2 AND 3 THEN 'Medium'
         ELSE 'High' END                            AS review_queue,
    CASE WHEN loan_amnt < 10000 THEN '<10K'
         WHEN loan_amnt < 20000 THEN '10-20K'
         ELSE '20K+' END                            AS loan_band,
    COUNT(*)                                        AS total_loans,
    SUM(default_flag)                               AS default_loans,
    ROUND(100 * AVG(default_flag), 2)               AS default_rate_pct,
    ROUND(SUM(loan_amnt) / 1000000.0, 1)            AS total_loan_amount_mn
FROM (
    SELECT
        default_flag,
        loan_amnt,
        (CASE WHEN fico_low < 700 THEN 2
              WHEN fico_low < 740 THEN 1
              ELSE 0 END)
        + (CASE WHEN dti IS NULL THEN 1
                WHEN dti < 20 THEN 0
                WHEN dti < 30 THEN 1
                ELSE 2 END)
        + (CASE WHEN term = '60 months' THEN 2 ELSE 0 END)
        AS risk_score
    FROM accepted_stg
)
GROUP BY review_queue, loan_band
ORDER BY MIN(risk_score), MIN(loan_amnt);




/* =====================================================================
   PART D: FINAL TABLE FOR POWER BI
   A table (not a view) was chosen because the 2007-2018 history never
   changes, and scoring 1.3M rows once is faster for the dashboard than
   re-scoring on every refresh. (A materialized view would also work.)
   Contains one row per loan with its score, tier, review flag, and
   (added below) band columns used for dashboard grouping.
   ===================================================================== */

-- Table for visualization (power bi)

-- D.1 One row per loan with risk score, tier, and manual-review flag.
-- Same scoring logic as Part B. s.* brings in every accepted_stg column
-- and risk_score is added; only the columns needed for the dashboard are
-- then selected.
CREATE TABLE loan_scored AS
SELECT
    id,
    issue_year,
    loan_amnt,
    term,
    grade,
    purpose,
    addr_state,
    home_ownership,
    emp_length,
    annual_inc,
    fico_low,
    dti,
    default_flag,
    risk_score,
    -- Tier: Low / Medium / High
    CASE WHEN risk_score <= 1 THEN 'Low'
         WHEN risk_score <= 3 THEN 'Medium'
         ELSE 'High' END AS risk_tier,
    -- Review rule: Medium tier + loan 20K or more
    CASE WHEN risk_score BETWEEN 2 AND 3 AND loan_amnt >= 20000
         THEN 1 ELSE 0 END AS manual_review_flag
FROM (
    SELECT
        s.*,
        (CASE WHEN fico_low < 700 THEN 2
              WHEN fico_low < 740 THEN 1
              ELSE 0 END)
        + (CASE WHEN dti IS NULL THEN 1
                WHEN dti < 20 THEN 0
                WHEN dti < 30 THEN 1
                ELSE 2 END)
        + (CASE WHEN term = '60 months' THEN 2 ELSE 0 END)
        AS risk_score
    FROM accepted_stg s
) ;

-- D.2 Checks on loan_scored (run one at a time).
-- Expected: total 1,344,989 | Low 276,454 / Medium 767,401 / High
-- 301,134 | manual review flag total 168,197
--SELECT COUNT(*) FROM loan_scored;                      -- expected 1,344,989
--SELECT risk_tier, COUNT(*) FROM loan_scored GROUP BY 1; -- expected Low 276,454 / Medium 767,401 / High 301,134
--SELECT SUM(manual_review_flag) FROM loan_scored;        -- expected 168,197


-- D.3 Add empty band columns. Each band has a text label and a numeric
-- order column. Power BI sorts text alphabetically, so it uses the
-- numeric column ("Sort by column") to show bands in the right order.
ALTER TABLE loan_scored ADD COLUMN fico_band TEXT;
ALTER TABLE loan_scored ADD COLUMN fico_band_order INT;
ALTER TABLE loan_scored ADD COLUMN dti_band Text;
ALTER TABLE loan_scored ADD COLUMN dti_band_order INT;
ALTER TABLE loan_scored ADD COLUMN income_band Text;
ALTER TABLE loan_scored ADD COLUMN income_band_order INT;
ALTER TABLE loan_scored ADD COLUMN loan_band text;
ALTER TABLE loan_scored ADD COLUMN loan_band_order INT;

-- D.4 Fill the band columns for every row (may take a minute).
-- Half-open ranges (< upper bound) are used so no value can fall into
-- two bands. Missing DTI gets its own 'Unknown' band, ordered last (5).
UPDATE loan_scored
SET fico_band = CASE WHEN fico_low < 700 THEN '<700'
                     WHEN fico_low < 740 THEN '700-739'
                     ELSE '740+' END,
    fico_band_order = CASE WHEN fico_low < 700 THEN 1
                           WHEN fico_low < 740 THEN 2
                           ELSE 3 END,
	dti_band = CASE WHEN dti IS NULL THEN 'Unknown'
					WHEN dti < 10 THEN '<10' 
					 WHEN dti < 20 THEN '10-20'
                     WHEN dti < 30 THEN '20-30'
					 ELSE '30+' END,
    dti_band_order = CASE WHEN dti IS NULL THEN 5
					WHEN dti < 10 THEN 1
					 WHEN dti < 20 THEN 2
                     WHEN dti < 30 THEN 3
					 ELSE 4 END,
	income_band = CASE WHEN annual_inc < 30000 THEN '<30k'
                     WHEN annual_inc < 50000 THEN '30-50k'
					 WHEN annual_inc < 75000 THEN '50-75k'
                     WHEN annual_inc < 100000 THEN '75-100k'
					 ELSE '100k+' END,
    income_band_order = CASE WHEN annual_inc < 30000 THEN 1
                     WHEN annual_inc < 50000 THEN 2
					 WHEN annual_inc < 75000 THEN 3
                     WHEN annual_inc < 100000 THEN 4
					 ELSE 5 END,
	loan_band = CASE WHEN loan_amnt < 10000 THEN '<10k'
                     WHEN loan_amnt < 20000 THEN '10-20k'
					 ELSE '20k+' END,
    loan_band_order = CASE WHEN loan_amnt < 10000 THEN 1
                     WHEN loan_amnt < 20000 THEN 2
					 ELSE 3 END;

-- D.5 Verify a band column. Counts should add up to 1,344,989; swap in
-- the other band names to check each one. No row should be NULL.
SELECT dti_band, COUNT(*)
FROM loan_scored
GROUP BY dti_band_order, dti_band
ORDER BY dti_band_order;


/* =====================================================================
   NOTE ON A STEP NOT SAVED IN THIS FILE
   The Power BI risk-tier chart sorts Low, Medium, High using an extra
   numeric column, risk_tier_order. It was created separately in pgAdmin
   and is not in the original file. The statements were:

     -- ALTER TABLE loan_scored ADD COLUMN risk_tier_order INT;
     -- UPDATE loan_scored
     -- SET risk_tier_order = CASE WHEN risk_tier = 'Low' THEN 1
     --                            WHEN risk_tier = 'Medium' THEN 2
     --                            ELSE 3 END;

   They are commented out so this file runs exactly as it did originally.
   Uncomment them if you rebuild loan_scored from scratch.
   ===================================================================== */
