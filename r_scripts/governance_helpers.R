# ============================================================
# r_scripts/governance_helpers.R
# r-healthcare-readmission — Governance Layer (Section 12)
# ============================================================
# Stage 2: ingest_metadata
# Stage 3: feature_registry
# Stage 4: model_registry
# Stage 5: fairness_reports
# Stage 6: rag_index_metadata, llm_call_log
# Stage 7: predictions_audit  ← added here
# ============================================================

library(DBI); library(uuid); library(digest); library(tibble)

write_ingest_metadata <- function(con, source, table_name, rows, data_hash,
                                  sensitivity_label = "SYNTHETIC", start_ts, end_ts) {
  if (sensitivity_label == "PHI" && Sys.getenv("ENV_MODE", "synthetic") != "production") {
    stop(sprintf("[GOVERNANCE] Ingest rejected: sensitivity='PHI' but ENV_MODE='%s'",
                 Sys.getenv("ENV_MODE", "synthetic")))
  }
  entry <- tibble(job_id = uuid::UUIDgenerate(), source = source, table_name = table_name,
                  rows = as.integer(rows), data_hash = data_hash, sensitivity_label = sensitivity_label,
                  operator = Sys.info()[["user"]], start_ts = start_ts, end_ts = end_ts)
  tbl_exists <- "ingest_metadata" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "ingest_metadata", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

write_feature_registry <- function(con, feature_name, version, window,
                                   computation_source, leakage_note,
                                   created_by, created_at = Sys.time()) {
  entry <- tibble(feature_name = feature_name, version = version, window = window,
                  computation_source = computation_source, leakage_note = leakage_note,
                  created_by = created_by, created_at = created_at)
  tbl_exists <- "feature_registry" %in% DBI::dbListTables(con)
  if (tbl_exists) {
    DBI::dbExecute(con, sprintf("DELETE FROM feature_registry WHERE feature_name='%s' AND version='%s'",
                                feature_name, version))
    DBI::dbWriteTable(con, "feature_registry", entry, append = TRUE)
  } else {
    DBI::dbWriteTable(con, "feature_registry", entry, overwrite = TRUE)
  }
  invisible(entry)
}

write_model_registry <- function(con, model_version, model_type, training_hash,
                                 chosen_threshold, recall, precision, f1,
                                 auc_roc, pr_auc, approved,
                                 clinical_signoff = "PENDING — synthetic data",
                                 fairness_report_path = "pending Stage 5",
                                 created_by, created_at = Sys.time()) {
  entry <- tibble(model_version = model_version, model_type = model_type,
                  training_hash = training_hash, chosen_threshold = chosen_threshold,
                  recall = recall, precision = precision, f1 = f1, auc_roc = auc_roc, pr_auc = pr_auc,
                  approved = approved, clinical_signoff = clinical_signoff,
                  fairness_report_path = fairness_report_path, created_by = created_by, created_at = created_at)
  tbl_exists <- "model_registry" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "model_registry", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

write_fairness_report <- function(con, model_version, model_type, dimension,
                                  subgroup_value, n, recall, precision, auc_roc,
                                  flagged_concern, created_by, created_at = Sys.time()) {
  entry <- tibble(model_version = model_version, model_type = model_type,
                  dimension = dimension, subgroup_value = subgroup_value, n = as.integer(n),
                  recall = recall, precision = precision, auc_roc = auc_roc,
                  flagged_concern = flagged_concern, created_by = created_by, created_at = created_at)
  tbl_exists <- "fairness_reports" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "fairness_reports", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

write_rag_index_metadata <- function(con, index_version, source_hash, n_documents,
                                     n_chunks, chunking_strategy, retrieval_strategy,
                                     created_by, created_at = Sys.time()) {
  entry <- tibble(index_version = index_version, source_hash = source_hash,
                  n_documents = as.integer(n_documents), n_chunks = as.integer(n_chunks),
                  chunking_strategy = chunking_strategy, retrieval_strategy = retrieval_strategy,
                  created_by = created_by, created_at = created_at)
  tbl_exists <- "rag_index_metadata" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "rag_index_metadata", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

write_llm_call_log <- function(con, trace_id, model_version, index_version, llm_model,
                               request_hash, response_hash, n_chunks_retrieved,
                               fallback_used, created_by, created_at = Sys.time()) {
  entry <- tibble(trace_id = trace_id, model_version = model_version,
                  index_version = index_version, llm_model = llm_model,
                  request_hash = request_hash, response_hash = response_hash,
                  n_chunks_retrieved = as.integer(n_chunks_retrieved), fallback_used = fallback_used,
                  created_by = created_by, created_at = created_at)
  tbl_exists <- "llm_call_log" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "llm_call_log", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

# ── write_predictions_audit(): Stage 7's governance write ──
# Append-only. Logs every inference call with hashes (never raw
# patient data or feature values) — complete audit trail without
# PHI storage risk. One row per /predict call.
write_predictions_audit <- function(con, trace_id, patient_id_hash, input_hash,
                                    model_version, risk_score, risk_tier,
                                    explanation_snippet, env, created_by,
                                    created_at = Sys.time()) {
  entry <- tibble(trace_id = trace_id, patient_id_hash = patient_id_hash,
                  input_hash = input_hash, model_version = model_version,
                  risk_score = risk_score, risk_tier = risk_tier,
                  explanation_snippet = explanation_snippet, env = env,
                  created_by = created_by, created_at = created_at)
  tbl_exists <- "predictions_audit" %in% DBI::dbListTables(con)
  DBI::dbWriteTable(con, "predictions_audit", entry, append = tbl_exists, overwrite = !tbl_exists)
  invisible(entry)
}

cat("[governance] governance_helpers.R loaded — all 7 write functions ready.\n")