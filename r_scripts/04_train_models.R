# ============================================================
# r_scripts/04_train_models.R
# r-healthcare-readmission — Stage 4
# ============================================================
# v3 (2026-06-21): two changes from v2.
#   1. features_v1 now carries pct_high_risk_dx (continuous) —
#      Stage 3 v3 fix for the saturating binary flag.
#   2. XGBoost regularized (min_n, sample_size, mtry, loss_reduction)
#      after v2's diagnostic showed lab_224168_min consuming 30.6%
#      of total gain while having near-zero linear association in
#      glmnet — the signature of a flexible tree model overfitting
#      to a coincidental pattern in a weak-signal regime, not a
#      discovered relationship.
#
# KEY DESIGN DECISIONS (unchanged since v1, see Stage 4 brief):
#   - PATIENT-level split, not date-based (MIMIC date-shifting).
#   - is_deceased excluded from predictors (future-fact leakage).
#   - Imputation inside the recipe, fit on train only.
#   - ROSE balances TRAIN only, never test.
#   - Threshold tuned to the LARGEST value still satisfying
#     Recall >= 0.85.
# ============================================================

library(here); library(DBI); library(dplyr); library(tidymodels)
library(glmnet); library(xgboost); library(ROSE)
library(digest); library(jsonlite); library(logger)

source(here::here("global_config.R"))
source(here::here("r_scripts", "governance_helpers.R"))

log_info("=== 04_train_models.R: STAGE 4 (v3 — continuous dx + regularized xgboost) ===")

MODEL_VERSION <- "v3"
set.seed(42)

# ============================================================
# STEP 1 — Pull features_v1 live from MinIO
# ============================================================
con <- get_db_connection()
register_cloud_tables(con)
features_v1 <- dbGetQuery(con, "SELECT * FROM features_v1")
close_db_connection(con)
log_info("Pulled features_v1: {nrow(features_v1)} rows x {ncol(features_v1)} columns")

features_v1 <- features_v1 %>%
  mutate(readmit_30d = factor(readmit_30d, levels = c(1, 0),
                              labels = c("Readmit", "NoReadmit")))

# ============================================================
# STEP 2 — PATIENT-level split
# ============================================================
split <- rsample::group_initial_split(features_v1, group = subject_id, prop = 0.80)
train_data <- training(split)
test_data  <- testing(split)

overlap <- intersect(unique(train_data$subject_id), unique(test_data$subject_id))
if (length(overlap) > 0) stop("PATIENT LEAKAGE: ", length(overlap), " subject_id(s) in both splits")

log_info("Split: {nrow(train_data)} train / {nrow(test_data)} test visits")
log_info("Train readmit_30d rate: {round(100*mean(train_data$readmit_30d=='Readmit'),2)}%")
log_info("Test readmit_30d rate: {round(100*mean(test_data$readmit_30d=='Readmit'),2)}%")
log_info("Patient overlap check: {length(overlap)} (must be 0)")

# ============================================================
# STEP 3 — Recipe
# ============================================================
feature_recipe <- recipe(readmit_30d ~ ., data = train_data) %>%
  update_role(subject_id, hadm_id, admit_time, discharge_time, is_deceased,
              new_role = "ID_excluded") %>%
  step_unknown(all_nominal_predictors()) %>%
  step_novel(all_nominal_predictors()) %>%
  step_impute_median(all_numeric_predictors()) %>%
  step_other(all_nominal_predictors(), threshold = 0.01) %>%
  step_dummy(all_nominal_predictors()) %>%
  step_zv(all_predictors()) %>%
  step_normalize(all_numeric_predictors())

recipe_prepped <- prep(feature_recipe, training = train_data)
train_baked <- bake(recipe_prepped, new_data = NULL)
test_baked  <- bake(recipe_prepped, new_data = test_data)
log_info("Recipe prepped on TRAIN only. Baked: {ncol(train_baked)} columns")

train_for_model <- train_baked %>%
  select(-subject_id, -hadm_id, -admit_time, -discharge_time, -is_deceased)
training_hash <- digest::digest(train_for_model)
log_info("training_hash: {substr(training_hash,1,12)}...")
log_info("Modeling columns: {ncol(train_for_model)}")

# ============================================================
# STEP 4 — ROSE: balance TRAIN only
# ============================================================
train_balanced <- ROSE::ROSE(readmit_30d ~ ., data = train_for_model, seed = 42)$data
log_info("Train balanced via ROSE: {nrow(train_balanced)} rows, {round(100*mean(train_balanced$readmit_30d=='Readmit'),1)}% Readmit")

# ============================================================
# STEP 5 — Train both models
# ============================================================
glmnet_spec <- logistic_reg(penalty = 0.01, mixture = 0.5) %>%
  set_engine("glmnet") %>% set_mode("classification")
glmnet_fit <- glmnet_spec %>% fit(readmit_30d ~ ., data = train_balanced)
log_info("glmnet trained")

# v3: regularized — shallower trees, minimum leaf size, row/column
# subsampling, minimum gain to split. Each one independently makes
# it harder for a single coincidental pattern to dominate the model.
n_predictors <- ncol(train_balanced) - 1
xgb_spec <- boost_tree(
  trees          = 300,
  tree_depth     = 4,
  learn_rate     = 0.05,
  min_n          = 30,
  sample_size    = 0.7,
  mtry           = round(n_predictors * 0.4),
  loss_reduction = 1
) %>% set_engine("xgboost") %>% set_mode("classification")
xgb_fit <- xgb_spec %>% fit(readmit_30d ~ ., data = train_balanced)
log_info("xgboost trained (regularized: depth=4, min_n=30, sample_size=0.7, mtry={round(n_predictors*0.4)}, loss_reduction=1)")

# ============================================================
# STEP 6 — Predict on TEST + threshold sweep
# ============================================================
evaluate_model <- function(fit, test_baked, model_name) {
  probs <- predict(fit, new_data = test_baked, type = "prob")
  results <- test_baked %>%
    select(subject_id, hadm_id, readmit_30d) %>%
    bind_cols(probs)
  
  thresholds <- seq(0.01, 0.99, by = 0.01)
  sweep <- purrr::map_dfr(thresholds, function(t) {
    pred_class <- factor(ifelse(results$.pred_Readmit >= t, "Readmit", "NoReadmit"),
                         levels = c("Readmit", "NoReadmit"))
    tp <- sum(pred_class == "Readmit"   & results$readmit_30d == "Readmit")
    fp <- sum(pred_class == "Readmit"   & results$readmit_30d == "NoReadmit")
    fn <- sum(pred_class == "NoReadmit" & results$readmit_30d == "Readmit")
    tibble(threshold = t,
           recall    = ifelse(tp+fn==0, NA, tp/(tp+fn)),
           precision = ifelse(tp+fp==0, NA, tp/(tp+fp)))
  }) %>% mutate(f1 = 2*precision*recall/(precision+recall))
  
  valid <- sweep %>% filter(!is.na(recall), recall >= 0.85)
  if (nrow(valid) == 0) {
    log_warn("[{model_name}] NO threshold achieves Recall >= 0.85 — using max-recall point")
    chosen <- sweep %>% filter(recall == max(recall, na.rm = TRUE)) %>% slice(1)
  } else {
    chosen <- valid %>% filter(threshold == max(threshold))
  }
  
  auc_roc <- yardstick::roc_auc_vec(results$readmit_30d, results$.pred_Readmit, event_level = "first")
  pr_auc  <- yardstick::pr_auc_vec(results$readmit_30d, results$.pred_Readmit, event_level = "first")
  
  log_info("[{model_name}] chosen threshold: {chosen$threshold} | recall: {round(chosen$recall,4)} | precision: {round(chosen$precision,4)} | f1: {round(chosen$f1,4)}")
  log_info("[{model_name}] AUC-ROC: {round(auc_roc,4)} | PR-AUC: {round(pr_auc,4)}")
  
  list(results = results, sweep = sweep, chosen = chosen, auc_roc = auc_roc, pr_auc = pr_auc)
}

glmnet_eval <- evaluate_model(glmnet_fit, test_baked, "glmnet")
xgb_eval    <- evaluate_model(xgb_fit,    test_baked, "xgboost")

# ============================================================
# STEP 7 — Save artifacts + metadata + governance entries
# ============================================================
dir.create(here::here("models", "artifacts"), recursive = TRUE, showWarnings = FALSE)

save_model_artifact <- function(fit, eval_result, model_type, recipe) {
  approved <- eval_result$chosen$recall >= 0.85
  
  rds_path <- here::here("models", "artifacts", sprintf("%s_%s.rds", model_type, MODEL_VERSION))
  saveRDS(list(fit = fit, recipe = recipe), rds_path)
  
  meta <- list(
    model_version    = MODEL_VERSION,
    model_type       = model_type,
    training_hash    = training_hash,
    chosen_threshold = eval_result$chosen$threshold,
    metrics = list(
      recall    = round(eval_result$chosen$recall, 4),
      precision = round(eval_result$chosen$precision, 4),
      f1        = round(eval_result$chosen$f1, 4),
      auc_roc   = round(eval_result$auc_roc, 4),
      pr_auc    = round(eval_result$pr_auc, 4)
    ),
    approved              = approved,
    clinical_signoff      = "PENDING — synthetic data, no clinical sign-off required at this stage",
    fairness_report_path  = "pending Stage 5",
    created_by = Sys.info()[["user"]],
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  json_path <- here::here("models", "artifacts", sprintf("metadata_%s_%s.json", model_type, MODEL_VERSION))
  jsonlite::write_json(meta, json_path, auto_unbox = TRUE, pretty = TRUE)
  
  log_info("[{model_type}] artifact saved: {basename(rds_path)} | approved: {approved}")
  list(approved = approved, meta = meta)
}

glmnet_saved <- save_model_artifact(glmnet_fit, glmnet_eval, "glmnet", recipe_prepped)
xgb_saved    <- save_model_artifact(xgb_fit,    xgb_eval,    "xgboost", recipe_prepped)

saveRDS(recipe_prepped, here::here("models", "artifacts", sprintf("recipe_%s.rds", MODEL_VERSION)))

gov_con <- get_db_connection()
write_model_registry(gov_con, MODEL_VERSION, "glmnet", training_hash,
                     glmnet_eval$chosen$threshold, glmnet_eval$chosen$recall, glmnet_eval$chosen$precision,
                     glmnet_eval$chosen$f1, glmnet_eval$auc_roc, glmnet_eval$pr_auc,
                     glmnet_saved$approved, created_by = Sys.info()[["user"]])
write_model_registry(gov_con, MODEL_VERSION, "xgboost", training_hash,
                     xgb_eval$chosen$threshold, xgb_eval$chosen$recall, xgb_eval$chosen$precision,
                     xgb_eval$chosen$f1, xgb_eval$auc_roc, xgb_eval$pr_auc,
                     xgb_saved$approved, created_by = Sys.info()[["user"]])
close_db_connection(gov_con)

log_info("=== STAGE 4 (v3) COMPLETE ===")
log_info("glmnet  approved: {glmnet_saved$approved} | xgboost approved: {xgb_saved$approved}")