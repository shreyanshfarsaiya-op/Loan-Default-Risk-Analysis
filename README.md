# Loan Default Risk Analysis

**Which customer segments have the highest loan default probability, and which applications should the credit team manually review?**

A PostgreSQL and Power BI project on 1.34 million LendingClub loans (2007-2018): segment analysis, a simple risk scorecard, and a rule for manual credit review.

## Key results

- **Baseline default rate: 19.97%** (268,531 defaults in 1,344,989 loans with a known outcome).
- **FICO score, loan term and DTI are the strongest signals.** FICO 740+ defaults at 9.65% vs 23.59% below 700. 60-month loans default at 32.45%, twice the 36-month rate (16.00%).
- **A 3-factor scorecard (FICO, DTI, term) ranks risk almost as well as LendingClub's own A-G grades:** default rate rises at every step from 6.20% (score 0) to 48.78% (score 6), a 7.9x spread vs 8.3x for the lender's grades.
- **Manual review rule: Medium risk tier and loan of $20K or more.** 168,197 applications (12.5% of the book), $4.42B in loans, 19.68% default rate, a genuine grey zone.

## Approach

1. **Staging (PostgreSQL):** kept only loans with a final outcome (Fully Paid, Charged Off, Default) and only columns known at decision time, to avoid data leakage.
2. **Cleaning:** impossible DTI values set to NULL (535), zero-income rows removed (361), missing employment length labelled "Unknown" (78,516).
3. **Segment analysis:** default rate by FICO, DTI, income, term, purpose, state, home ownership and employment, with a 1,000-loan minimum per group.
4. **Scorecard:** points for FICO, DTI and term, grouped into Low, Medium and High tiers.
5. **Dashboard (Power BI):** three pages: Overview, Segments, Manual Review Queue.

## Main findings

| Signal | Lowest-risk | Highest-risk |
|---|---|---|
| FICO | 9.65% (740+) | 23.59% (below 700) |
| Loan term | 16.00% (36 months) | 32.45% (60 months) |
| DTI | 14.89% (under 10) | 29.18% (30+) |
| Income | 15.92% (100K+) | 24.38% (under 30K) |
| Purpose | 12.16% (wedding) | 29.70% (small business) |

- Signals stack: FICO below 700 on a 60-month loan defaults at 37.30%, vs 7.08% for FICO 740+ on 36 months.
- Loan size looked risky on its own but mostly was not: larger loans are more often 60-month, and the pattern faded once split by term.
- Missing employment information is itself a risk signal (26.95% default rate).

## Recommendation

| Tier | Loans | Default rate | Action |
|---|---|---|---|
| Low | 276,454 | 9.06% | Approve |
| Medium, loan $20K+ | 168,197 | 19.68% | **Manual review** |
| Medium, loan under $20K | 599,204 | about 17.9% | Standard process |
| High | 301,134 | 34.25% | Decline or senior sign-off |

The Medium tier is 57% of loans, too many to review by hand. Filtering to $20K+ keeps the queue small while covering about 44% of the tier's loan value, so reviewers focus where a wrong decision costs most.

## Dashboard

![Overview](screenshots/overview.png)
![Segments](screenshots/segments.png)
![Review Queue](screenshots/review_queue.png)

## Limitations

- The scorecard was tuned on the same data it was tested on, so real-world performance may be lower.
- Recent loans still running were excluded, so recent years look safer than they are.
- Results are associations, not causes.
- Single lender, single dataset.

## Repository

- `sql/` commented SQL scripts, to be run in numeric order
- `dashboard/` Power BI template
- `screenshots/` dashboard pages

**Tools:** PostgreSQL, Power BI
