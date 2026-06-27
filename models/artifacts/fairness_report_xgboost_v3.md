# Fairness Report — xgboost v3
Generated: 2026-06-22 04:44:37
Test set: 8274 visits | Threshold: 0.58
Model AUC-ROC: 0.5660

Subgroups with n < 30 are excluded from disparity flagging.
A concern is flagged if a dimension's recall range exceeds 15 percentage points.

## Results by dimension

|dimension |subgroup_value               |    n| recall| precision|flagged_concern |
|:---------|:----------------------------|----:|------:|---------:|:---------------|
|gender    |F                            | 3717|  0.892|     0.206|FALSE           |
|gender    |M                            | 4557|  0.880|     0.218|FALSE           |
|race      |BLACK/AFRICAN AMERICAN       | 1513|  0.869|     0.213|TRUE            |
|race      |BLACK/CAPE VERDEAN           |  104|  0.958|     0.228|TRUE            |
|race      |HISPANIC OR LATINO           |   55|  0.765|     0.283|TRUE            |
|race      |HISPANIC/LATINO - CUBAN      |  256|  0.830|     0.221|TRUE            |
|race      |HISPANIC/LATINO - SALVADORAN |   97|  0.130|     0.375|TRUE            |
|race      |OTHER                        |  141|  0.935|     0.230|TRUE            |
|race      |PORTUGUESE                   |  204|  0.828|     0.152|TRUE            |
|race      |UNABLE TO OBTAIN             |  127|  1.000|     0.195|TRUE            |
|race      |UNKNOWN                      |  451|  0.920|     0.220|TRUE            |
|race      |WHITE                        | 5140|  0.905|     0.211|TRUE            |
|race      |WHITE - BRAZILIAN            |   86|  0.950|     0.229|TRUE            |
|race      |WHITE - OTHER EUROPEAN       |   54|  0.800|     0.267|TRUE            |
|insurance |Medicaid                     |  614|  0.885|     0.194|FALSE           |
|insurance |Medicare                     | 3062|  0.881|     0.214|FALSE           |
|insurance |Other                        | 4598|  0.888|     0.213|FALSE           |

## Permutation importance (top 10)

|feature                | mean_auc_drop| sd_auc_drop|
|:----------------------|-------------:|-----------:|
|n_prior_admissions     |       0.04323|     0.00130|
|pct_high_risk_dx       |       0.01109|     0.00286|
|lab_229321_min         |       0.00145|     0.00135|
|lab_220052_min         |       0.00105|     0.00083|
|marital_status_Unknown |       0.00088|     0.00021|
|lab_220050_min         |       0.00083|     0.00016|
|lab_220045_mean        |       0.00070|     0.00030|
|lab_228096_max         |       0.00069|     0.00039|
|lab_220277_max         |       0.00064|     0.00044|
|race_PORTUGUESE        |       0.00054|     0.00026|
