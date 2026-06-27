# ============================================================
# api/plumber.R
# r-healthcare-readmission — Stage 7
# ============================================================
# Four endpoints:
#   GET  /health        — liveness check, no auth required
#   POST /predict       — risk score + top drivers + trace_id
#   POST /explain       — full per-feature explanation
#   POST /rag/summary   — RAG-cited discharge recommendation
#
# Design: core logic lives in named functions (*_core) so each
# endpoint can be tested directly without running an HTTP server.
# Plumber route decorators are thin wrappers around those functions.
#
# All /predict calls write to predictions_audit (Section 12).
# All /rag/summary calls write to llm_call_log (Section 12).
# Every response carries trace_id and model_version.
# ============================================================

library(here); library(DBI); library(dplyr); library(tidymodels)
library(uuid); library(digest); library(logger); library(jsonlite)

source(here::here("global_config.R"))
source(here::here("r_scripts", "governance_helpers.R"))
source(here::here("rag", "llm_wrapper.R"))

# ── Startup: load model artifacts (once, not per-request) ──
MODEL_VERSION  <- "v3"
THRESHOLD      <- 0.58
INDEX_VERSION  <- "v1"

# Top features from Stage 5 permutation importance (embedded as constants
# to avoid re-running Stage 5 on every API startup)
TOP_FEATURES <- c("n_prior_admissions", "pct_high_risk_dx",
                  "lab_229321_min", "lab_220052_min", "marital_status_Unknown")

# Training-set medians in normalized space (from Stage 5's explanation output)
TRAIN_MEDIANS <- c(
  n_prior_admissions   = -0.483,
  pct_high_risk_dx     = -0.347,
  lab_229321_min       = -0.107,
  lab_220052_min       = -0.062,
  marital_status_Unknown = -0.209
)

model_bundle   <- readRDS(here::here("models", "artifacts", sprintf("xgboost_%s.rds", MODEL_VERSION)))
xgb_fit        <- model_bundle$fit
recipe_prepped <- model_bundle$recipe
log_info("[API] xgboost_{MODEL_VERSION} loaded at startup")

# ── Helpers ──────────────────────────────────────────────────

get_patient_features <- function(hadm_id_val) {
  con <- get_db_connection()
  register_cloud_tables(con)
  row <- DBI::dbGetQuery(con,
                         sprintf("SELECT * FROM features_v1 WHERE hadm_id = %d LIMIT 1", as.integer(hadm_id_val)))
  close_db_connection(con)
  if (nrow(row) == 0) stop(sprintf("hadm_id %d not found in features_v1", hadm_id_val))
  row
}

classify_risk_tier <- function(score) {
  if (score >= THRESHOLD) "high" else if (score >= 0.30) "medium" else "low"
}

make_explanation <- function(baked_row) {
  parts <- sapply(TOP_FEATURES, function(f) {
    if (!f %in% names(baked_row)) return(sprintf("%s = NA", f))
    val   <- baked_row[[f]]
    med   <- TRAIN_MEDIANS[f]
    if (is.na(val)) return(sprintf("%s = NA", f))
    direction <- ifelse(val > med, "above", "below")
    sprintf("%s = %.2f (%+.2f %s median)", f, val, abs(val - med), direction)
  })
  paste(parts, collapse = " | ")
}

get_prediction_and_baked <- function(patient) {
  patient_f <- patient %>%
    mutate(readmit_30d = factor(readmit_30d, levels = c(1,0),
                                labels = c("Readmit","NoReadmit")))
  baked <- bake(recipe_prepped, new_data = patient_f)
  prob  <- predict(xgb_fit, new_data = baked, type = "prob")$.pred_Readmit[1]
  list(baked = baked, prob = prob)
}

# ── Core logic functions (testable without HTTP server) ──────

health_core <- function() {
  list(
    status        = "ok",
    model_version = MODEL_VERSION,
    index_version = INDEX_VERSION,
    timestamp     = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    endpoints     = c("/health", "/predict", "/explain", "/rag/summary")
  )
}

predict_core <- function(hadm_id) {
  hadm_id <- as.integer(hadm_id)
  patient <- get_patient_features(hadm_id)
  preds   <- get_prediction_and_baked(patient)
  expl    <- make_explanation(preds$baked)
  tier    <- classify_risk_tier(preds$prob)
  trace_id <- uuid::UUIDgenerate()
  
  gov_con <- get_db_connection()
  write_predictions_audit(gov_con,
                          trace_id            = trace_id,
                          patient_id_hash     = digest::digest(paste(patient$subject_id, hadm_id)),
                          input_hash          = digest::digest(patient),
                          model_version       = MODEL_VERSION,
                          risk_score          = preds$prob,
                          risk_tier           = tier,
                          explanation_snippet = substr(expl, 1, 200),
                          env                 = Sys.getenv("ENV_MODE", "synthetic"),
                          created_by          = Sys.info()[["user"]])
  close_db_connection(gov_con)
  
  list(
    trace_id       = trace_id,
    model_version  = MODEL_VERSION,
    hadm_id        = hadm_id,
    subject_id     = patient$subject_id,
    predicted_risk = round(preds$prob, 4),
    risk_tier      = tier,
    threshold      = THRESHOLD,
    flagged        = preds$prob >= THRESHOLD,
    top_drivers    = expl,
    disclaimer     = "FOR PORTFOLIO DEMONSTRATION ONLY — NOT FOR CLINICAL USE. Model trained on 100-patient synthetic data (AUC-ROC 0.566)."
  )
}

explain_core <- function(hadm_id) {
  hadm_id  <- as.integer(hadm_id)
  patient  <- get_patient_features(hadm_id)
  preds    <- get_prediction_and_baked(patient)
  trace_id <- uuid::UUIDgenerate()
  
  feature_details <- lapply(TOP_FEATURES, function(f) {
    val <- if (f %in% names(preds$baked)) preds$baked[[f]] else NA
    med <- TRAIN_MEDIANS[f]
    list(
      feature   = f,
      value     = round(val, 3),
      median    = round(med, 3),
      delta     = round(val - med, 3),
      direction = ifelse(!is.na(val) && val > med, "above_median", "below_median"),
      note      = "Value is in recipe-normalized space (step_normalize applied)"
    )
  })
  
  list(
    trace_id         = trace_id,
    model_version    = MODEL_VERSION,
    hadm_id          = hadm_id,
    predicted_risk   = round(preds$prob, 4),
    risk_tier        = classify_risk_tier(preds$prob),
    explanation      = feature_details,
    permutation_rank = as.list(setNames(seq_along(TOP_FEATURES), TOP_FEATURES)),
    disclaimer       = "FOR PORTFOLIO DEMONSTRATION ONLY — NOT FOR CLINICAL USE."
  )
}

rag_summary_core <- function(hadm_id, icd_families = "general") {
  hadm_id  <- as.integer(hadm_id)
  patient  <- get_patient_features(hadm_id)
  preds    <- get_prediction_and_baked(patient)
  icd_list <- trimws(strsplit(icd_families, ",")[[1]])
  
  result <- generate_discharge_summary(
    subject_id         = patient$subject_id,
    hadm_id            = hadm_id,
    predicted_risk     = preds$prob,
    top_feature_names  = TOP_FEATURES,
    icd_families       = icd_list,
    los_days           = patient$los_days,
    n_prior_admissions = patient$n_prior_admissions,
    model_version      = MODEL_VERSION,
    index_version      = INDEX_VERSION
  )
  
  list(
    trace_id         = result$trace_id,
    model_version    = MODEL_VERSION,
    hadm_id          = hadm_id,
    predicted_risk   = round(preds$prob, 4),
    risk_tier        = classify_risk_tier(preds$prob),
    summary          = result$summary_text,
    citations        = result$citations,
    retrieval_debug  = result$retrieval_debug$top_chunks,
    disclaimer       = "FOR PORTFOLIO DEMONSTRATION ONLY — NOT FOR CLINICAL USE. Guideline documents are synthetic and do not represent real clinical protocols."
  )
}

# ── Plumber route definitions (thin wrappers) ────────────────

#* @apiTitle Healthcare Readmission Forecasting API
#* @apiDescription Production-grade readmission risk prediction with RAG-cited discharge summaries. FOR PORTFOLIO DEMONSTRATION ONLY.

#* Liveness check
#* @get /health
function() health_core()

#* Predict 30-day readmission risk
#* @param hadm_id Hospital admission ID
#* @post /predict
function(hadm_id) predict_core(hadm_id)

#* Full per-feature risk explanation
#* @param hadm_id Hospital admission ID
#* @post /explain
function(hadm_id) explain_core(hadm_id)

#* RAG-cited discharge summary
#* @param hadm_id Hospital admission ID
#* @param icd_families Comma-separated ICD family prefixes (e.g. "I50,J44")
#* @post /rag/summary
function(hadm_id, icd_families = "general") rag_summary_core(hadm_id, icd_families)