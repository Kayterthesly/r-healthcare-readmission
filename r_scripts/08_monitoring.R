# ============================================================
# r_scripts/08_monitoring.R
# r-healthcare-readmission — Stage 8
# ============================================================
# Reads from all governance tables in local DuckDB and produces
# a timestamped markdown monitoring report in logs/.
#
# Can be run:
# - Manually: source("r_scripts/08_monitoring.R")
# - On a schedule (Windows Task Scheduler / cron)
# - Triggered from GitHub Actions
#
# Drift detection requires >= 30 rows in predictions_audit.
# With fewer, it reports "INSUFFICIENT DATA" — the framework is
# ready to compute PSI the moment enough data accumulates.
# ============================================================

library(here); library(DBI); library(dplyr); library(logger)

source(here::here("global_config.R"))
log_info("=== 08_monitoring.R: STAGE 8 MONITORING ===")

REPORT_DATE      <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
REPORT_FILE      <- sprintf("monitoring_report_%s.md", format(Sys.time(), "%Y%m%d_%H%M%S"))
REPORT_PATH      <- here::here("logs", REPORT_FILE)
DRIFT_MIN_N      <- 30
RECALL_THRESHOLD <- 0.85

# ============================================================
# STEP 1 — Pull all governance tables
# ============================================================
con <- get_db_connection()

model_reg   <- tryCatch(dbGetQuery(con, "SELECT * FROM model_registry ORDER BY model_version, model_type"), error = function(e) NULL)
feature_reg <- tryCatch(dbGetQuery(con, "SELECT * FROM feature_registry"), error = function(e) NULL)
ingest_meta <- tryCatch(dbGetQuery(con, "SELECT * FROM ingest_metadata ORDER BY start_ts DESC"), error = function(e) NULL)
fairness_rp <- tryCatch(dbGetQuery(con, "SELECT * FROM fairness_reports WHERE model_version='v3'"), error = function(e) NULL)
pred_audit  <- tryCatch(dbGetQuery(con, "SELECT * FROM predictions_audit"), error = function(e) NULL)
llm_log     <- tryCatch(dbGetQuery(con, "SELECT * FROM llm_call_log"), error = function(e) NULL)
rag_meta    <- tryCatch(dbGetQuery(con, "SELECT * FROM rag_index_metadata"), error = function(e) NULL)

close_db_connection(con)
log_info("Governance tables pulled — model_registry: {ifelse(is.null(model_reg),0,nrow(model_reg))} | predictions_audit: {ifelse(is.null(pred_audit),0,nrow(pred_audit))}")

# ============================================================
# STEP 2 — Model health
# ============================================================
approved_models  <- if (!is.null(model_reg)) filter(model_reg, approved == TRUE) else data.frame()
recall_gate_pass <- nrow(approved_models) > 0 && all(approved_models$recall >= RECALL_THRESHOLD, na.rm = TRUE)
best_model       <- if (nrow(approved_models) > 0) approved_models %>% arrange(desc(auc_roc)) %>% slice(1) else NULL

# ============================================================
# STEP 3 — Prediction volume and drift
# ============================================================
pred_n <- if (!is.null(pred_audit)) nrow(pred_audit) else 0

if (pred_n >= DRIFT_MIN_N) {
  # PSI: approximate training risk-score distribution from Stage 4 metadata
  train_dist <- c(0.35, 0.25, 0.15, 0.08, 0.06, 0.04, 0.03, 0.02, 0.01, 0.01)
  bins       <- seq(0, 1, by = 0.1)
  inf_counts <- hist(pred_audit$risk_score, breaks = bins, plot = FALSE)$counts
  inf_pct    <- inf_counts / max(sum(inf_counts), 1)
  psi        <- sum((inf_pct - train_dist) * log((inf_pct + 1e-6) / (train_dist + 1e-6)))
  drift_status <- if (psi < 0.10) "LOW" else if (psi < 0.25) "MODERATE" else "HIGH"
  drift_note   <- sprintf("PSI = %.4f (%s)", psi, drift_status)
} else {
  drift_status <- "INSUFFICIENT_DATA"
  drift_note   <- sprintf("N=%d predictions logged (minimum %d required for PSI drift analysis — framework ready)", pred_n, DRIFT_MIN_N)
}

# ============================================================
# STEP 4 — Fairness summary
# ============================================================
if (!is.null(fairness_rp) && nrow(fairness_rp) > 0) {
  fairness_rp <- fairness_rp %>% mutate(excluded_small_n = n < 30)
  fairness_flagged <- sum(fairness_rp$flagged_concern, na.rm = TRUE)
  fairness_total   <- nrow(fairness_rp %>% filter(!excluded_small_n))
  fairness_status  <- if (fairness_flagged == 0) "CLEAR" else sprintf("FLAGGED (%d of %d adequately-sized subgroups)", fairness_flagged, fairness_total)
} else {
  fairness_flagged <- 0; fairness_total <- 0; fairness_status <- "NO_DATA"
}

# ============================================================
# STEP 5 — LLM call log summary
# ============================================================
llm_total        <- if (!is.null(llm_log)) nrow(llm_log) else 0
llm_fallback     <- if (!is.null(llm_log)) sum(llm_log$fallback_used, na.rm = TRUE) else 0
llm_fallback_pct <- if (llm_total > 0) round(100 * llm_fallback / llm_total, 1) else 0

# ============================================================
# STEP 6 — Governance completeness
# ============================================================
gov_checks <- list(
  ingest_metadata    = !is.null(ingest_meta) && nrow(ingest_meta) > 0,
  feature_registry   = !is.null(feature_reg) && nrow(feature_reg) > 0,
  model_registry     = !is.null(model_reg)   && nrow(model_reg)   > 0,
  fairness_reports   = !is.null(fairness_rp) && nrow(fairness_rp) > 0,
  rag_index_metadata = !is.null(rag_meta)    && nrow(rag_meta)    > 0,
  llm_call_log       = !is.null(llm_log)     && nrow(llm_log)     > 0,
  predictions_audit  = !is.null(pred_audit)
)
gov_complete <- all(unlist(gov_checks))
gov_row_counts <- c(
  ifelse(is.null(ingest_meta),0,nrow(ingest_meta)),
  ifelse(is.null(feature_reg),0,nrow(feature_reg)),
  ifelse(is.null(model_reg),0,nrow(model_reg)),
  ifelse(is.null(fairness_rp),0,nrow(fairness_rp)),
  ifelse(is.null(rag_meta),0,nrow(rag_meta)),
  ifelse(is.null(llm_log),0,nrow(llm_log)),
  ifelse(is.null(pred_audit),0,nrow(pred_audit))
)

# ============================================================
# STEP 7 — Log summary to console
# ============================================================
overall_status <- ifelse(recall_gate_pass && gov_complete, "HEALTHY", "ATTENTION_REQUIRED")

log_info("=== MONITORING SUMMARY ===")
log_info("Approved models: {nrow(approved_models)} | Recall gate: {ifelse(recall_gate_pass,'PASS','FAIL')}")
log_info("Prediction volume: N={pred_n} | Drift: {drift_status}")
log_info("Fairness: {fairness_status}")
log_info("LLM calls: {llm_total} total | Fallback rate: {llm_fallback_pct}%")
log_info("Governance tables complete: {gov_complete}")
log_info("Overall status: {overall_status}")

# ============================================================
# STEP 8 — Write markdown report to logs/
# ============================================================
dir.create(here::here("logs"), showWarnings = FALSE)

con_lines <- function(...) paste(..., sep = "\n")

report <- paste(c(
  "# Healthcare Readmission Pipeline — Monitoring Report",
  sprintf("**Generated:** %s  ", REPORT_DATE),
  sprintf("**Environment:** %s  ", Sys.getenv("ENV_MODE", "synthetic")),
  sprintf("**Overall status:** %s", ifelse(overall_status=="HEALTHY","✅ HEALTHY","⚠️ ATTENTION REQUIRED")),
  "",
  "---",
  "",
  "## 1. Model Health",
  "",
  "| Metric | Value |",
  "|--------|-------|",
  sprintf("| Approved models | %d |", nrow(approved_models)),
  sprintf("| Recall gate (≥ %.2f) | %s |", RECALL_THRESHOLD, ifelse(recall_gate_pass, "✅ PASS", "❌ FAIL")),
  if (!is.null(best_model))
    sprintf("| Reference model | %s %s — AUC-ROC %.4f, Recall %.4f |",
            best_model$model_type, best_model$model_version, best_model$auc_roc, best_model$recall)
  else "| Reference model | None registered |",
  "",
  "## 2. Prediction Volume & Drift",
  "",
  "| Metric | Value |",
  "|--------|-------|",
  sprintf("| Predictions logged | %d |", pred_n),
  sprintf("| Drift minimum N | %d |", DRIFT_MIN_N),
  sprintf("| Drift status | %s |", drift_status),
  sprintf("| Drift note | %s |", drift_note),
  "",
  "## 3. Fairness Status",
  "",
  if (!is.null(fairness_rp) && nrow(fairness_rp) > 0) {
    dim_summary <- fairness_rp %>%
      filter(!excluded_small_n) %>%
      group_by(dimension) %>%
      summarise(tested = n(), flagged = sum(flagged_concern, na.rm=TRUE), .groups="drop")
    c("| Dimension | Subgroups Tested | Flagged | Status |",
      "|-----------|-----------------|---------|--------|",
      apply(dim_summary, 1, function(r)
        sprintf("| %s | %s | %s | %s |", r["dimension"], r["tested"], r["flagged"],
                ifelse(as.integer(r["flagged"]) > 0, "⚠️ Concern", "✅ Clear"))))
  } else "*(No fairness data)*",
  "",
  "## 4. LLM Call Log",
  "",
  "| Metric | Value |",
  "|--------|-------|",
  sprintf("| Total LLM calls | %d |", llm_total),
  sprintf("| Fallback rate | %d/%d = %.1f%% |", llm_fallback, llm_total, llm_fallback_pct),
  sprintf("| Real Gemini calls | %d/%.0f = %.1f%% |", llm_total-llm_fallback, as.numeric(llm_total), 100-llm_fallback_pct),
  "",
  "## 5. Governance Completeness",
  "",
  "| Table | Status | Rows |",
  "|-------|--------|------|",
  sprintf("| ingest_metadata | %s | %d |", ifelse(gov_checks$ingest_metadata,"✅","❌"), gov_row_counts[1]),
  sprintf("| feature_registry | %s | %d |", ifelse(gov_checks$feature_registry,"✅","❌"), gov_row_counts[2]),
  sprintf("| model_registry | %s | %d |", ifelse(gov_checks$model_registry,"✅","❌"), gov_row_counts[3]),
  sprintf("| fairness_reports | %s | %d |", ifelse(gov_checks$fairness_reports,"✅","❌"), gov_row_counts[4]),
  sprintf("| rag_index_metadata | %s | %d |", ifelse(gov_checks$rag_index_metadata,"✅","❌"), gov_row_counts[5]),
  sprintf("| llm_call_log | %s | %d |", ifelse(gov_checks$llm_call_log,"✅","❌"), gov_row_counts[6]),
  sprintf("| predictions_audit | %s | %d |", ifelse(gov_checks$predictions_audit,"✅","❌"), gov_row_counts[7]),
  "",
  "---",
  "",
  sprintf("*Report: %s*", REPORT_PATH)
), collapse = "\n")

writeLines(report, REPORT_PATH)
log_info("Report written: logs/{REPORT_FILE}")
log_info("=== MONITORING COMPLETE — Status: {overall_status} ===")

monitoring_result <- list(
  timestamp        = REPORT_DATE,
  report_path      = REPORT_PATH,
  overall_status   = overall_status,
  approved_models  = nrow(approved_models),
  recall_gate      = recall_gate_pass,
  prediction_n     = pred_n,
  drift_status     = drift_status,
  fairness_flagged = fairness_flagged,
  llm_total        = llm_total,
  llm_fallback_pct = llm_fallback_pct,
  gov_complete     = gov_complete
)
invisible(monitoring_result)