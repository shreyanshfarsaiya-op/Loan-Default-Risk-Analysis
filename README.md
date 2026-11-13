# Loan Default Risk Analysis

**Which customer segments have the highest loan default probability, and which applications should the credit team manually review?**

An end-to-end banking analytics project using PostgreSQL and Power BI on 1.34 million LendingClub loans (2007-2018). It identifies the borrower segments that default most, builds a simple and explainable risk scorecard, and defines a rule for which applications deserve a human credit review.

---

## Headline results

- **Baseline default rate: 19.97%** (268,531 defaults out of 1,344,989 loans with a known outcome).
- **FICO score, loan term and debt-to-income (DTI) are the strongest usable signals.** Borrowers with FICO 740+ default at 9.65%, against 23.59% below 700. 60-month loans default at 32.45%, twice the 16.00% of 36-month loans.
- **A simple 3-factor scorecard ranks risk almost as well as LendingClub's own A-G grades:** default rate rises at every step from 6.20% (score 0) to 48.78% (score 6), a 7.9x spread, against 8.3x for the lender's grades.
- **Manual review rule: Medium-risk tier and loan amount of $20K or more.** This flags 168,197 applications (12.5% of all loans) worth $4.42B, with a default rate of 19.68%, a genuine grey zone where human judgement adds the most value.

---

## Dataset

Publicly available LendingClub loan data, 2007 to 2018 Q4:

| Table | Rows | Used for |
|---|---|---|
| Accepted loans | 2,260,701 | All analysis. About 150 columns per loan, including the final loan outcome. |
| Rejected applications | about 27.6 million | Not used for default rates. It has only 9 columns and no outcome, so there is nothing to compute a default rate from. |

---

## Approach

The project follows a layered pipeline, so every step can be traced and rebuilt:

**Raw table, then staging table, then scored table, then dashboard**

### 1. Load and stage (PostgreSQL)
- Loaded the raw CSV with every column as TEXT, so the import cannot fail on messy values.
- Built a staging table with only the columns known **at the moment of the credit decision**. Columns recorded after a loan is issued (payments received, recoveries, hardship and settlement fields) were dropped on purpose to avoid **data leakage**.
- Kept only loans with a **final outcome**: Fully Paid, Charged Off or Default. Current, Late and Grace Period loans were excluded because their outcome is not yet known, and treating them as "not defaulted" would understate risk. Older loans issued under a previous credit policy were also excluded.
- Defined the target: `default_flag = 1` for Charged Off or Default, `0` for Fully Paid.

### 2. Data quality checks and cleaning
| Issue | Rows | Treatment |
|---|---|---|
| DTI negative or above 100 (impossible or placeholder values) | 535 | Set to NULL, loan kept |
| Annual income of zero | 361 | Deleted (treated as data errors) |
| Missing employment length | 78,516 | Labelled "Unknown" instead of deleted, since missing data turned out to be a risk signal |

Final modelling set: **1,344,989 loans**.

### 3. Segment analysis
Default rate (`AVG(default_flag)`) by income, loan term, purpose, state, home ownership, employment length, FICO band and DTI band, each compared with the 19.97% baseline. Segments with fewer than 1,000 loans were excluded because their rates are too noisy to trust. Every query was checked by reconciling its totals back to 1,344,989.

### 4. Risk scorecard
Each loan earns points for three factors, and the points add up (0 = safest, 6 = riskiest):

| Factor | 0 points | 1 point | 2 points |
|---|---|---|---|
| FICO score | 740+ | 700-739 | Below 700 |
| DTI | Under 20 | 20 to under 30 | 30 or more |
| Loan term | 36 months | - | 60 months |

Loans with a missing DTI (548) receive 1 point, a neutral middle value, so their score is not lost. LendingClub's own grade was deliberately **not** used as an input. It is the lender's own model output, so it is used only as an independent benchmark.

### 5. Dashboard (Power BI)
A three-page dashboard connected to the final `loan_scored` table, with default rate, review queue and review exposure calculated as measures so they respond to filters.

---

## Key findings

### Default rate by segment (baseline 19.97%)

| Signal | Lowest-risk group | Highest-risk group | Gap |
|---|---|---|---|
| LendingClub grade (benchmark) | 6.04% (A) | 49.92% (G) | 8.3x |
| FICO score | 9.65% (740+) | 23.59% (below 700) | 2.4x |
| Loan purpose | 12.16% (wedding) | 29.70% (small business) | 2.4x |
| Loan term | 16.00% (36 months) | 32.45% (60 months) | 2.0x |
| DTI | 14.89% (under 10) | 29.18% (30+) | 2.0x |
| State | 13.21% (DC) | 26.09% (Mississippi) | 2.0x (extremes are small states) |
| Annual income | 15.92% (100K+) | 24.38% (under 30K) | 1.5x |
| Home ownership | 17.21% (mortgage) | 23.22% (rent) | 1.35x |
| Employment length | 18.78% (10+ years) | 26.95% (not recorded) | 1.4x |

### Observations worth noting
- **Signals stack.** A borrower with FICO below 700 on a 60-month loan defaults at 37.30%, against 7.08% for FICO 740+ on a 36-month loan, a 5x gap. This is why a combined score beats any single column.
- **Loan size looked like a risk factor, but mostly was not.** Default rate rises from 15.49% (under $5K) to 24.23% ($30K+), but larger loans are far more often 60-month loans. Splitting each size band by term removed most of the pattern, so term is the real driver (a confounding effect).
- **Missing employment information is itself a risk signal.** Loans with no employment length recorded default at 26.95%, which is why they were kept as their own group.
- **Debt consolidation drives total losses by volume.** It is 58% of all loans at 21.15%, so it produces about 61% of all defaults even though its rate is only slightly above average. Small business loans are the riskiest purpose but make up only about 1% of loans.
- **State effects are moderate.** The highest and lowest states are small; large states sit close together (California 19.61%, Texas 19.82%, New York 22.05%). The differences may partly reflect borrower income or credit mix rather than location itself.

### Scorecard performance

| Risk score | Loans | Default rate |
|---|---|---|
| 0 | 80,761 | 6.20% |
| 1 | 195,693 | 10.24% |
| 2 | 491,978 | 16.18% |
| 3 | 275,423 | 22.05% |
| 4 | 200,194 | 30.34% |
| 5 | 77,538 | 39.95% |
| 6 | 23,402 | 48.78% |

The rate rises at every step, and the spread (7.9x) nearly matches LendingClub's own grades (8.3x), using only three columns and equal weights.

Scores were grouped into three tiers:

| Tier | Score | Loans | Default rate | Share of loans | Share of all defaults |
|---|---|---|---|---|---|
| Low | 0-1 | 276,454 | 9.06% | 21% | 9% |
| Medium | 2-3 | 767,401 | 18.29% | 57% | 52% |
| High | 4-6 | 301,134 | 34.25% | 22% | 38% |

---

## Recommendation for the credit team

| Tier | Suggested action |
|---|---|
| **Low** | Standard approval. Loan size makes no meaningful difference to risk here (about 9% at every size). |
| **Medium and loan of $20K or more** | **Manual review.** 168,197 applications, $4.42B in loans, default rate 19.68%. |
| **Medium and loan under $20K** | Standard process. |
| **High** | Decline, or require senior sign-off. Default rate is about 35% for loans of $10K and above (26% under $10K). |

**Why this review rule:** the Medium tier holds 57% of loans, which is far too many for people to review. Narrowing it to loans of $20K or more cuts the queue to 22% of the Medium tier while keeping about 44% of its loan value, so reviewers spend their time where a wrong decision costs the most. Within the Medium tier, default rate rises only slightly with loan size (17.71% to 19.68%), so the $20K cut-off selects for **exposure** (money at stake), not for extra risk. The queue's default rate sits almost exactly at the portfolio average, which is what makes it a true grey zone.

---

## Dashboard

Three pages built in Power BI, with a consistent teal palette:

1. **Overview:** headline cards (total loans, defaults, default rate, review queue, review exposure), default rate by risk tier, loans by tier, and default rate by issue year.
2. **Segments:** default rate by FICO band, DTI band, income band, loan term, loan purpose and state.
3. **Manual Review Queue:** how the queue narrows from 1.34M loans to 168K, default rate by loan size within the Medium tier, and a sample of applications in the queue.

Screenshots are in the `screenshots` folder.

---

## Limitations

- **The scorecard was tuned on the same data it was tested on.** The factors and cut-offs were chosen after exploring this dataset, so performance on new applications is likely somewhat lower. A stronger version would build the score on earlier years and validate it on later years.
- **Recent loans look safer than they are.** Many 2017-2018 loans are still running and were excluded, so only early failures appear. The drop in default rate in the final year of the trend chart is not a real improvement.
- **Late loans (31-120 days) were excluded** because their outcome is unknown. Many will eventually charge off, so treating them as defaults would be a useful sensitivity check.
- **Equal weights.** Each factor in the scorecard carries the same weight. Tuning the weights could improve ranking.
- **Patterns are associations, not causes.** State and loan-size differences in particular may reflect other factors, as the term analysis showed for loan size.
- **The review queue shown is historical.** In practice the queue is built at decision time, when the outcome is unknown. The sample table on the dashboard illustrates what the queue looks like.
- **Missing DTI** (548 loans) was scored as a neutral middle value. The effect on results is negligible because of the small count.
- **Single dataset, single lender.** Findings describe LendingClub's borrowers and may not generalise to other lenders or time periods.

---

## Tools

- **PostgreSQL** (pgAdmin 4 and psql): loading, cleaning, staging, analysis and scoring
- **Power BI Desktop:** data model, DAX measures and dashboard

---

## Repository structure

```
.
├── README.md
├── sql/
│   ├── 01_staging_cleaning_and_segment_analysis.sql
│   └── 02_crosstabs_scoring_and_powerbi_table.sql
├── dashboard/
│   └── (Power BI template file)
└── screenshots/
    ├── overview.png
    ├── segments.png
    └── review_queue.png
```

The SQL files are commented and should be run in numeric order.
