/* =====================================================================
   LOAN DEFAULT RISK PROJECT  |  File 1 of 2
   Staging, data-quality checks, cleaning, and single-signal analysis
   ---------------------------------------------------------------------
   Business question:
     Which customer segments have the highest loan default probability,
     and which applications should the credit team manually review?

   Data: LendingClub accepted loans 2007-2018Q4 (about 2.26M rows).
   The rejected-applications table has no outcome column, so default
   rates cannot be computed from it and it is not used in this analysis.

   PREREQUISITE (done before this file, in psql / pgAdmin):
     1. accepted_raw was created with every column as TEXT, so the CSV
        import cannot fail on messy values.
     2. The CSV was loaded from the psql tool (not the pgAdmin import
        wizard) with:
          \copy accepted_raw FROM 'C:/path/to/accepted_2007_to_2018Q4.csv'
                WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
        Result: COPY 2260701

   PIPELINE:   accepted_raw  ->  accepted_stg  ->  (File 2) loan_scored
               raw copy          cleaned/typed       Power BI table

   Run the statements in the order they appear in this file.
   Default definition used throughout: default_flag = 1 means
   'Charged Off' or 'Default'; 0 means 'Fully Paid'.
   ===================================================================== */


/* =====================================================================
   STEP 1: BUILD THE STAGING TABLE
   - Keep only loans with a FINAL outcome (Fully Paid, Charged Off,
     Default). Current / Late / Grace Period loans are excluded because
     we do not yet know how they end; counting them as 'not defaulted'
     would understate risk.
   - Create default_flag, the target variable.
   - Cast text columns to proper numeric / date types.
   - Keep ~30 of the 150 columns. Columns recorded AFTER a loan is
     issued (total_pymnt, recoveries, last_pymnt_d, out_prncp,
     hardship_*, settlement_*, ...) are dropped on purpose to avoid
     DATA LEAKAGE: the credit team would not know them at decision time.
   Expected result: 1,345,350 rows.
   ===================================================================== */

CREATE TABLE accepted_stg AS
SELECT
    id,

    -- TARGET: 1 = borrower failed to repay, 0 = repaid in full
    CASE WHEN loan_status IN ('Charged Off','Default') THEN 1 ELSE 0 END AS default_flag,
    loan_status,

    -- DATES: text like 'Dec-2015' converted to a real date, plus a year column for trend analysis
    to_date(issue_d, 'Mon-YYYY')                         AS issue_date,
    EXTRACT(YEAR FROM to_date(issue_d, 'Mon-YYYY'))::int AS issue_year,

    -- LOAN TERMS
    loan_amnt::numeric   AS loan_amnt,
    TRIM(term)           AS term,
    int_rate::numeric    AS int_rate,
    installment::numeric AS installment,
    grade,
    sub_grade,

    -- BORROWER PROFILE
    emp_length,
    home_ownership,
    annual_inc::numeric  AS annual_inc,
    verification_status,
    purpose,
    addr_state,
    application_type,

    -- CREDIT HISTORY
    dti::numeric                  AS dti,
    delinq_2yrs::numeric          AS delinq_2yrs,
    fico_range_low::numeric       AS fico_low,
    fico_range_high::numeric      AS fico_high,
    inq_last_6mths::numeric       AS inq_last_6mths,
    open_acc::numeric             AS open_acc,
    pub_rec::numeric              AS pub_rec,
    revol_bal::numeric            AS revol_bal,
    revol_util::numeric           AS revol_util,
    total_acc::numeric            AS total_acc,
    mort_acc::numeric             AS mort_acc,
    pub_rec_bankruptcies::numeric AS pub_rec_bankruptcies

FROM accepted_raw
-- Keep only loans with a finished outcome
WHERE loan_status IN ('Fully Paid','Charged Off','Default');


-- CHECK: split of defaulted vs repaid loans in the staging table.
-- Expected: about 20% flagged as 1 (the baseline default rate).
SELECT default_flag, COUNT(*) AS loans,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM accepted_stg
GROUP BY default_flag;


/* =====================================================================
   STEP 2: DATA-QUALITY CHECKS (before any cleaning)
   Always size a problem before fixing it.
   ===================================================================== */

-- Missing values per column. COUNT(col) skips NULLs and COUNT(*) does
-- not, so the difference equals the number of NULLs.
-- Result: total_rows 1,345,350 | null_income 0 | null_dti 374 |
--         null_emp_length 78,516 | null_revol_util 857 |
--         null_mort_acc 47,281 | null_bankruptcies 697 | null_fico 0
-- Decision: only emp_length (5.8%) needs special handling (see Step 3).
SELECT
  COUNT(*)                                            AS total_rows,
  COUNT(*) - COUNT(annual_inc)                        AS null_income,
  COUNT(*) - COUNT(dti)                               AS null_dti,
  COUNT(*) - COUNT(emp_length)                        AS null_emp_length,
  COUNT(*) - COUNT(revol_util)                        AS null_revol_util,
  COUNT(*) - COUNT(mort_acc)                          AS null_mort_acc,
  COUNT(*) - COUNT(pub_rec_bankruptcies)              AS null_bankruptcies,
  COUNT(*) - COUNT(fico_low)                          AS null_fico
FROM accepted_stg;


-- Range check for impossible or extreme values.
-- Result: income 0 to 10,999,200 | dti -1 to 999 | FICO 625 to 845 |
--         loan amount 500 to 40,000
-- Findings: dti of -1 and 999 are impossible/placeholder values, and
-- income of 0 is suspicious. FICO and loan amount look plausible.
SELECT
  MIN(annual_inc) AS min_inc,  MAX(annual_inc) AS max_inc,
  MIN(dti)        AS min_dti,  MAX(dti)        AS max_dti,
  MIN(fico_low)   AS min_fico, MAX(fico_low)   AS max_fico,
  MIN(loan_amnt)  AS min_loan, MAX(loan_amnt)  AS max_loan
FROM accepted_stg;


-- Size the bad values before deciding how to treat them.
-- Result: negative_dti 2 | dti_over_100 533 | zero_income 361
-- That is about 0.07% of rows, so a simple fix will not change results.
SELECT
  COUNT(*) FILTER (WHERE dti < 0)        AS negative_dti,
  COUNT(*) FILTER (WHERE dti > 100)      AS dti_over_100,
  COUNT(*) FILTER (WHERE annual_inc = 0) AS zero_income
FROM accepted_stg;

-- Quick visual inspection of the staging table (exploration only).
select * FROM accepted_stg;


/* =====================================================================
   STEP 3: CLEANING
   Run each statement once. Rows affected should be 535, 361 and 78,516.
   ===================================================================== */

-- Impossible DTI values (negative, or the 999 placeholder) become NULL.
-- The loan is kept because its other fields are valid; only the bad
-- value is marked as missing.
UPDATE accepted_stg
SET dti = NULL
WHERE dti < 0 OR dti > 100;

-- A borrower with zero income should not be an approved loan, so these
-- rows are treated as data errors and deleted. These rows most likely
-- also carried the DTI placeholder (DTI cannot be computed from zero
-- income), which would explain why the NULL DTI count below is 548 and
-- not 374 + 535 = 909.
DELETE FROM accepted_stg
WHERE annual_inc = 0;

-- Missing employment length is labelled 'Unknown' instead of deleted,
-- because missing information can itself be a risk signal (it is: see
-- the employment analysis in File 2, where Unknown defaults at 26.95%).
UPDATE accepted_stg
SET emp_length = 'Unknown'
WHERE emp_length IS NULL;


-- CHECK after cleaning.
-- Expected: total_loans 1,344,989 | default_rate_pct 19.97 | null_dti 548
-- 19.97% is the BASELINE every segment is compared against.
SELECT COUNT(*) AS total_loans,
       ROUND(100 * AVG(default_flag), 2) AS default_rate_pct,
       COUNT(*) FILTER (WHERE dti IS NULL) AS null_dti
FROM accepted_stg;


/* =====================================================================
   STEP 4: SINGLE-SIGNAL SEGMENT ANALYSIS
   Pattern used in every query below:
     default rate = AVG(default_flag)   (the flag is 1 or 0)
   Compare each group to the 19.97% baseline. After each query, check
   that group totals add up to 1,344,989.
   ===================================================================== */

-- 4.1 DEFAULT RATE BY LOAN TERM
-- Result: 60 months 324,442 loans, 32.45% | 36 months 1,020,547 loans, 16.00%
-- Finding: 60-month loans default at about twice the 36-month rate.
SELECT 
TERM,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS ,
ROUND(100 * AVG(DEFAULT_FLAG),2) AS DEFAULT_RATE_PCT 
FROM ACCEPTED_STG
GROUP BY TERM
ORDER BY DEFAULT_RATE_PCT DESC


-- 4.2 DEFAULT RATE BY INCOME BRACKET
-- CASE assigns each loan to a band; the first matching WHEN wins.
-- Result: <30K 24.38% | 30-50K 22.59% | 50-75K 20.48% | 75-100K 18.26% | 100K+ 15.72%
-- Finding: default rate falls steadily as income rises (about 1.5x gap).
-- NOTE: BETWEEN includes both ends, so an income of exactly 50,000 is
-- matched by the 30-50K branch first. File 2's Power BI table uses
-- half-open ranges (< 50000, < 75000, ...) instead, so a few counts
-- differ slightly between this query and the dashboard.
SELECT 
CASE WHEN ANNUAL_INC < 30000 THEN '<30K'
	WHEN ANNUAL_INC BETWEEN 30000 AND 50000 THEN '30-50K'
	WHEN ANNUAL_INC BETWEEN 50000 AND 75000 THEN '50-75K'
	WHEN ANNUAL_INC BETWEEN 75000 AND 100000 THEN '75-100K'
	ELSE '100K+'
END AS INCOME_BRACKET,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS ,
ROUND(100 * AVG(DEFAULT_FLAG),2) AS DEFAULT_RATE_PCT 
FROM ACCEPTED_STG
GROUP BY INCOME_BRACKET
ORDER BY DEFAULT_RATE_PCT DESC

-- 4.3 DEFAULT RATE BY DEBT-TO-INCOME (DTI) BAND
-- DTI = monthly debt payments / monthly income, in %.
-- The IS NULL branch sits before ELSE so the 548 loans with missing DTI
-- get their own 'Unknown' group instead of silently landing in '40+'.
-- Finding: default rate climbs from about 15% (DTI under 10) to about
-- 29-30% (DTI above 30), roughly double.
-- NOTE: ORDER BY DTI_BANDS sorts alphabetically; it only looks right
-- here because of how the labels happen to sort. File 2 uses a numeric
-- band_order column for reliable ordering.
SELECT
CASE WHEN DTI < 10 THEN '<10'
	WHEN DTI < 20 THEN '10-20'
	WHEN DTI < 30 THEN '20-30'
	WHEN DTI < 40 THEN '30-40'
	WHEN DTI IS NULL THEN 'Unknown'
	ELSE '40+'
END AS DTI_BANDS,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG) * 100), 2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY DTI_BANDS
ORDER BY DTI_BANDS

-- 4.4 DEFAULT RATE BY FICO BAND (first version, four bands)
-- FICO is a credit score (300-850); higher means safer. fico_low is the
-- low end of LendingClub's 4-point score band.
-- band_order (numeric) is used for ORDER BY so bands never sort
-- alphabetically.
-- Result: <660 2 loans, 0.00% | 660-699 23.59% | 700-740 16.06% | 740+ 9.65%
-- Finding: the strongest single borrower signal (about 2.4x gap). The
-- <660 band has only 2 loans, so its rate is meaningless.
-- NOTE: the cut-offs are < 699 and < 739 while the labels say 699 / 740.
-- It still works because FICO values here move in steps of 5.
SELECT 
CASE WHEN FICO_LOW < 660 THEN 1
	WHEN FICO_LOW < 699 THEN 2
	WHEN FICO_LOW < 739 THEN 3
	ELSE 4
END AS BAND_ORDER,
CASE WHEN FICO_LOW < 660 THEN '<660'
	WHEN FICO_LOW < 699 THEN '660-699'
	WHEN FICO_LOW < 739 THEN '700-740'
	ELSE '740+'
END AS FICO_BAND,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG)*100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY FICO_BAND, BAND_ORDER
ORDER BY BAND_ORDER 


-- 4.5 DEFAULT RATE BY LOAN PURPOSE
-- HAVING filters whole groups after aggregation (WHERE filters rows
-- before). Groups under 1,000 loans are dropped because a rate based on
-- very few loans is too noisy to trust.
-- Result: 12 purposes kept (1,259 loans in tiny groups dropped).
-- small_business is highest at 29.70%; wedding is lowest at 12.16%.
-- debt_consolidation is 58% of all loans (21.15%), so it drives the
-- largest share of total defaults.
SELECT 
purpose,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS ,
ROUND(100 * AVG(DEFAULT_FLAG),2) AS DEFAULT_RATE_PCT 
FROM ACCEPTED_STG
GROUP BY PURPOSE
HAVING COUNT(*) >= 1000
ORDER BY DEFAULT_RATE_PCT DESC


-- 4.6 DEFAULT RATE BY HOME OWNERSHIP
-- Same minimum-volume rule (478 loans in rare categories dropped).
-- Result: RENT 23.22% | OWN 20.62% | MORTGAGE 17.21%
-- Finding: mortgage holders are safest, renters riskiest (about 1.35x).
-- Weaker signal than FICO, term or DTI.
SELECT
HOME_OWNERSHIP,
COUNT(*) AS TOTAL_LOANS,
SUM(DEFAULT_FLAG) AS DEFAULT_LOANS,
ROUND((AVG(DEFAULT_FLAG) * 100),2) AS DEFAULT_RATE_PERC
FROM ACCEPTED_STG
GROUP BY HOME_OWNERSHIP
HAVING COUNT(*) >= 1000
ORDER BY DEFAULT_RATE_PERC DESC

/* End of File 1. Continue with File 2: cross-tabs, risk scorecard,
   review rule, and the Power BI table. */
