# ============================================================
# r_scripts/05_explainability_fairness.R
# r-healthcare-readmission — Stage 5
# ============================================================
# Works against xgboost_v3 only (the reference model from Stage 4).
#
# Per-patient explanations use a PURE R approach rather than
# xgboost's native predcontrib. Reason: predcontrib requires
# constructing an xgb.DMatrix which hits a Windows-specific memory
# alignment check in XGBoost 3.x (array_interface.h:422,
# ptr % alignment == 0) that is unreliable to fix without
# rebuilding the package from source.
#
# The pure R approach is actually more clinically interpretable:
# for each high-risk patient, it reports how far their top-5
# permutation-important features sit from the population median,
# with explicit direction (+above / -below), so a clinician can
# read "n_prior_admissions = 8 (+5.2 above median)" directly rather
# than an opaque SHAP value.
# ============================================================

library(here); library(DBI); library(dplyr); library(tidymodels)
library(xgboost); library(jsonlite); library(logger)

source(here::here("global_config.R"))
source(here::here("r_scripts", "governance_helpers.R"))

log_info("=== 05_explainability_fairness.R: STAGE 5 ===")

MODEL_VERSION    <- "v3"
MIN_SUBGROUP_N   <- 30
TOP_N_REVIEW     <- 15
N_PERM_REPEATS   <- 3
TOP_N_EXPLAIN    <- 5   # features shown per clinician review case

# ============================================================
# STEP 1 — Reload v3 model + recipe, reproduce the test split
# ============================================================
model_bundle   <- readRDS(here::here("models", "artifacts",
                                     sprintf("xgboost_%s.rds", MODEL_VERSION)))
xgb_fit        <- model_bundle$fit
recipe_prepped <- model_bundle$recipe
log_info("Loaded xgboost_{MODEL_VERSION} + its prepped recipe")

con <- get_db_connection()
register_cloud_tables(con)
features_v1 <- dbGetQuery(con, "SELECT * FROM features_v1 ORDER BY subject_id, hadm_id")
close_db_connection(con)

features_v1 <- features_v1 %>%
  mutate(readmit_30d = factor(readmit_30d, levels = c(1, 0),
                              labels = c("Readmit", "NoReadmit")))

set.seed(42)
split      <- rsample::group_initial_split(features_v1, group = subject_id, prop = 0.80)
train_data <- training(split)
test_data  <- testing(split)
log_info("Reproduced test split: {nrow(test_data)} visits (must match Stage 4's 8,274)")

train_baked <- bake(recipe_prepped, new_data = NULL)
test_baked  <- bake(recipe_prepped, new_data = test_data)

# ── Predictions on the test set ──
probs <- predict(xgb_fit, new_data = test_baked, type = "prob")
results <- test_baked %>%
  select(subject_id, hadm_id, readmit_30d) %>%
  bind_cols(probs) %>%
  left_join(test_data %>% select(subject_id, hadm_id, gender, race, insurance),
            by = c("subject_id", "hadm_id"))

CHOSEN_THRESHOLD <- 0.58
results <- results %>%
  mutate(pred_class = factor(ifelse(.pred_Readmit >= CHOSEN_THRESHOLD, "Readmit", "NoReadmit"),
                             levels = c("Readmit", "NoReadmit")))

baseline_auc <- yardstick::roc_auc_vec(results$readmit_30d, results$.pred_Readmit,
                                       event_level = "first")
log_info("Baseline AUC-ROC (sanity check, should match Stage 4's 0.566): {round(baseline_auc,4)}")

# ============================================================
# STEP 2 — Permutation importance (manual, AUC-drop based)
# ============================================================
log_info("=== Permutation importance ({N_PERM_REPEATS} repeats per feature) ===")

id_cols        <- c("subject_id", "hadm_id", "admit_time", "discharge_time",
                    "is_deceased", "readmit_30d")
predictor_cols <- setdiff(names(test_baked), id_cols)

perm_importance <- purrr::map_dfr(predictor_cols, function(col) {
  drops <- numeric(N_PERM_REPEATS)
  for (r in seq_len(N_PERM_REPEATS)) {
    shuffled <- test_baked
    shuffled[[col]] <- sample(shuffled[[col]])
    sp <- predict(xgb_fit, new_data = shuffled, type = "prob")$.pred_Readmit
    sa <- yardstick::roc_auc_vec(test_baked$readmit_30d, sp, event_level = "first")
    drops[r] <- baseline_auc - sa
  }
  tibble(feature = col, mean_auc_drop = mean(drops), sd_auc_drop = sd(drops))
}) %>% arrange(desc(mean_auc_drop))

log_info("Top 15 features by permutation importance:")
print(head(perm_importance, 15))

# ============================================================
# STEP 3 — Per-patient explanations (pure R, no DMatrix required)
#
# Approach: for each high-risk review patient, report how far
# their value for each top-N permutation-important feature sits
# from the training-set median, with direction.
# Clinically readable: "n_prior_admissions = 8 (+5.2 above median)"
# is more immediately useful than a raw SHAP value.
# ============================================================
log_info("=== Per-patient explanations (pure R, permutation-feature based) ===")

top_explain_features <- head(perm_importance$feature, TOP_N_EXPLAIN)

# Training medians (computed on train_baked — never on test)
train_medians <- sapply(top_explain_features, function(f) {
  median(train_baked[[f]], na.rm = TRUE)
})
log_info("Training medians for top {TOP_N_EXPLAIN} features:")
print(round(train_medians, 3))

get_patient_explanation <- function(row_idx) {
  patient_row <- test_baked[row_idx, ]
  parts <- sapply(top_explain_features, function(f) {
    val    <- patient_row[[f]]
    med    <- train_medians[f]
    delta  <- val - med
    if (is.na(val)) {
      sprintf("%s = NA (missing)", f)
    } else {
      direction <- ifelse(delta > 0, "above", "below")
      sprintf("%s = %.2f (%+.2f %s median %.2f)", f, val, abs(delta), direction, med)
    }
  })
  paste(parts, collapse = " | ")
}

# ============================================================
# STEP 4 — Clinician review case set: top N highest-risk patients
# ============================================================
review_cases <- results %>%
  arrange(desc(.pred_Readmit)) %>%
  slice_head(n = TOP_N_REVIEW) %>%
  mutate(row_idx = match(paste(subject_id, hadm_id),
                         paste(test_baked$subject_id, test_baked$hadm_id)))

review_cases$top_drivers <- sapply(review_cases$row_idx, get_patient_explanation)

review_output <- review_cases %>%
  transmute(
    subject_id, hadm_id,
    predicted_risk     = round(.pred_Readmit, 4),
    actual_readmit_30d = ifelse(readmit_30d == "Readmit", 1, 0),
    top_drivers,
    clinical_signoff   = "PENDING — synthetic data, no clinical sign-off required at this stage"
  )

log_info("Clinician review case set built: {nrow(review_output)} cases")

review_path <- here::here("models", "artifacts",
                          sprintf("clinician_review_cases_%s.csv", MODEL_VERSION))
write.csv(review_output, review_path, row.names = FALSE)
log_info("Saved: {review_path}")

# Show top 3 cases as a sanity print
log_info("Sample clinician review cases (top 3 by predicted risk):")
print(review_output[1:3, c("subject_id","hadm_id","predicted_risk",
                           "actual_readmit_30d")])
cat("\nTop driver explanation for case #1:\n")
cat(review_output$top_drivers[1], "\n")

# ============================================================
# STEP 5 — Fairness: stratify by race, gender, insurance
# ============================================================
log_info("=== Fairness stratification (threshold={CHOSEN_THRESHOLD}) ===")

compute_subgroup_metrics <- function(data, dimension) {
  data %>%
    group_by(.data[[dimension]]) %>%
    summarise(
      n  = n(),
      tp = sum(pred_class == "Readmit"   & readmit_30d == "Readmit"),
      fp = sum(pred_class == "Readmit"   & readmit_30d == "NoReadmit"),
      fn = sum(pred_class == "NoReadmit" & readmit_30d == "Readmit"),
      .groups = "drop"
    ) %>%
    mutate(
      recall    = ifelse(tp+fn==0, NA, tp/(tp+fn)),
      precision = ifelse(tp+fp==0, NA, tp/(tp+fp)),
      dimension = dimension
    ) %>%
    rename(subgroup_value = 1) %>%
    select(dimension, subgroup_value, n, recall, precision)
}

fairness_gender    <- compute_subgroup_metrics(results, "gender")
fairness_race      <- compute_subgroup_metrics(results, "race")
fairness_insurance <- compute_subgroup_metrics(results, "insurance")

fairness_all <- bind_rows(fairness_gender, fairness_race, fairness_insurance)

# Flag within each dimension separately — a concern exists if
# the LARGEST recall gap between adequately-sized subgroups in
# the same dimension exceeds 15 percentage points
flag_dimension <- function(df, dim_name) {
  sub <- df %>% filter(dimension == dim_name, n >= MIN_SUBGROUP_N, !is.na(recall))
  if (nrow(sub) < 2) return(rep(FALSE, nrow(df)))
  rng <- max(sub$recall) - min(sub$recall)
  concern <- rng > 0.15
  (df$dimension == dim_name) & (df$n >= MIN_SUBGROUP_N) & !is.na(df$recall) & concern
}

fairness_all <- fairness_all %>%
  mutate(
    excluded_small_n = n < MIN_SUBGROUP_N,
    flagged_concern   = flag_dimension(., "gender") |
      flag_dimension(., "race")   |
      flag_dimension(., "insurance")
  )

log_info("{sum(fairness_all$excluded_small_n)} subgroup(s) excluded (n < {MIN_SUBGROUP_N})")
print(fairness_all %>% arrange(dimension, desc(n)))

# ============================================================
# STEP 6 — Governance rows + markdown summary
# ============================================================
gov_con <- get_db_connection()
for (i in seq_len(nrow(fairness_all))) {
  row <- fairness_all[i, ]
  write_fairness_report(gov_con, MODEL_VERSION, "xgboost",
                        dimension       = row$dimension,
                        subgroup_value  = as.character(row$subgroup_value),
                        n               = row$n,
                        recall          = row$recall,
                        precision       = row$precision,
                        auc_roc         = NA,
                        flagged_concern = isTRUE(row$flagged_concern),
                        created_by      = Sys.info()[["user"]])
}
close_db_connection(gov_con)
log_info("{nrow(fairness_all)} fairness_reports rows written")

report_path <- here::here("models", "artifacts",
                          sprintf("fairness_report_xgboost_%s.md", MODEL_VERSION))
report_lines <- c(
  sprintf("# Fairness Report — xgboost %s", MODEL_VERSION),
  sprintf("Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  sprintf("Test set: %d visits | Threshold: %.2f", nrow(results), CHOSEN_THRESHOLD),
  sprintf("Model AUC-ROC: %.4f", baseline_auc),
  "",
  paste0("Subgroups with n < ", MIN_SUBGROUP_N, " are excluded from disparity flagging."),
  "A concern is flagged if a dimension's recall range exceeds 15 percentage points.",
  "",
  "## Results by dimension",
  "",
  knitr::kable(
    fairness_all %>%
      filter(!excluded_small_n, !is.na(recall)) %>%
      mutate(recall    = round(recall, 3),
             precision = round(precision, 3)) %>%
      select(dimension, subgroup_value, n, recall, precision, flagged_concern),
    format = "markdown"
  ),
  "",
  "## Permutation importance (top 10)",
  "",
  knitr::kable(
    head(perm_importance, 10) %>%
      mutate(mean_auc_drop = round(mean_auc_drop, 5),
             sd_auc_drop   = round(sd_auc_drop,   5)),
    format = "markdown"
  )
)
writeLines(report_lines, report_path)
log_info("Saved fairness report: {report_path}")

log_info("=== STAGE 5 COMPLETE ===")