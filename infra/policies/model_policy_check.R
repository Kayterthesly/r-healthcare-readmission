# ============================================================
# infra/policies/model_policy_check.R
# r-healthcare-readmission — Stage 8
# ============================================================
# R-native equivalent of OPA/Rego policy enforcement.
#
# v2 fix (2026-06-23): Policy 4's section search was looking for
# literal "Section 12" and "Section 13" — the decisions doc uses
# numbered heading format "## 12." and "## 13." Updated to match
# both formats so the check is robust regardless of phrasing in
# the section body text.
# ============================================================

library(here); library(DBI); library(dplyr); library(jsonlite); library(logger)

source(here::here("global_config.R"))

run_policy_check <- function() {
  log_info("=== Policy check starting ===")
  checks <- list()
  
  # ── POLICY 1: At least one approved model must exist ─────
  con         <- get_db_connection()
  model_reg   <- tryCatch(dbGetQuery(con, "SELECT * FROM model_registry"), error = function(e) NULL)
  feature_reg <- tryCatch(dbGetQuery(con, "SELECT * FROM feature_registry"), error = function(e) NULL)
  close_db_connection(con)
  
  has_approved <- !is.null(model_reg) && any(model_reg$approved, na.rm = TRUE)
  checks[["policy_1_approved_model"]] <- list(
    passed  = has_approved,
    message = if (has_approved) "Policy 1 PASS: At least one approved model in model_registry"
    else               "Policy 1 FAIL: No approved models in model_registry"
  )
  
  # ── POLICY 2: All approved models must meet recall >= 0.85 ─
  if (!is.null(model_reg)) {
    approved  <- model_reg %>% filter(approved == TRUE)
    recall_ok <- nrow(approved) == 0 || all(approved$recall >= 0.85, na.rm = TRUE)
  } else { recall_ok <- FALSE }
  checks[["policy_2_recall_gate"]] <- list(
    passed  = recall_ok,
    message = if (recall_ok) "Policy 2 PASS: All approved models satisfy Recall >= 0.85"
    else            "Policy 2 FAIL: One or more approved models below Recall 0.85 threshold"
  )
  
  # ── POLICY 3: feature_registry must document leakage notes ─
  leakage_ok <- !is.null(feature_reg) && nrow(feature_reg) > 0 &&
    all(nchar(feature_reg$leakage_note) > 0, na.rm = TRUE)
  checks[["policy_3_leakage_notes"]] <- list(
    passed  = leakage_ok,
    message = if (leakage_ok) "Policy 3 PASS: All feature_registry entries carry leakage_note documentation"
    else             "Policy 3 FAIL: One or more features missing leakage_note"
  )
  
  # ── POLICY 4: Locked decisions doc must have Sections 4, 12, 13 ─
  # The decisions doc uses numbered heading format "## N." as well as
  # prose references like "Section N". Both patterns are accepted.
  decisions_path <- here::here("docs", "00_locked_decisions.md")
  if (file.exists(decisions_path)) {
    content <- paste(readLines(decisions_path, warn = FALSE), collapse = "\n")
    
    # Section 4 appears as prose "Section 4" (in decisions written before this convention)
    # Sections 12 and 13 appear as headings "## 12." / "## 13." — match both patterns
    has_sec4  <- grepl("Section 4",   content, fixed = TRUE)
    has_sec12 <- grepl("## 12\\.",    content)  || grepl("Section 12", content, fixed = TRUE)
    has_sec13 <- grepl("## 13\\.",    content)  || grepl("Section 13", content, fixed = TRUE)
    
    missing_secs <- c(
      if (!has_sec4)  "Section 4"  else NULL,
      if (!has_sec12) "Section 12 (heading '## 12.' or prose 'Section 12')" else NULL,
      if (!has_sec13) "Section 13 (heading '## 13.' or prose 'Section 13')" else NULL
    )
    doc_ok <- length(missing_secs) == 0
    
    checks[["policy_4_decisions_doc"]] <- list(
      passed  = doc_ok,
      message = if (doc_ok)
        "Policy 4 PASS: Locked decisions doc contains all required sections (4, 12, 13)"
      else
        sprintf("Policy 4 FAIL: Missing sections: %s", paste(missing_secs, collapse=", "))
    )
  } else {
    checks[["policy_4_decisions_doc"]] <- list(
      passed  = FALSE,
      message = "Policy 4 FAIL: docs/00_locked_decisions.md not found"
    )
  }
  
  # ── POLICY 5: All model metadata JSON files must be valid ──
  meta_files      <- list.files(here::here("models","artifacts"), pattern="metadata_.*\\.json", full.names=TRUE)
  required_fields <- c("model_version","model_type","training_hash","chosen_threshold","metrics","approved")
  
  if (length(meta_files) == 0) {
    json_ok  <- FALSE
    json_msg <- "Policy 5 FAIL: No model metadata JSON files found in models/artifacts/"
  } else {
    json_errors <- character(0)
    for (f in meta_files) {
      tryCatch({
        meta    <- jsonlite::fromJSON(f)
        missing <- setdiff(required_fields, names(meta))
        if (length(missing) > 0) json_errors <- c(json_errors, sprintf("%s missing: %s", basename(f), paste(missing, collapse=",")))
      }, error = function(e) {
        json_errors <<- c(json_errors, sprintf("%s: invalid JSON", basename(f)))
      })
    }
    json_ok  <- length(json_errors) == 0
    json_msg <- if (json_ok)
      sprintf("Policy 5 PASS: %d model metadata JSON files validated (%s)",
              length(meta_files), paste(sapply(meta_files, basename), collapse=", "))
    else
      sprintf("Policy 5 FAIL: %s", paste(json_errors, collapse="; "))
  }
  checks[["policy_5_metadata_json"]] <- list(passed = json_ok, message = json_msg)
  
  # ── POLICY 6: All required pipeline scripts must exist ────
  required_scripts <- c(
    "global_config.R",
    "r_scripts/governance_helpers.R",
    "r_scripts/01_synthetic_mimic_generator.R",
    "r_scripts/02_ingest_and_cast.R",
    "r_scripts/03_features.R",
    "r_scripts/04_train_models.R",
    "r_scripts/05_explainability_fairness.R",
    "r_scripts/08_monitoring.R",
    "schemas/canonical_omop_schemas.R",
    "rag/rag_indexing.R",
    "rag/llm_wrapper.R",
    "api/plumber.R"
  )
  missing_scripts <- required_scripts[!file.exists(here::here(required_scripts))]
  scripts_ok      <- length(missing_scripts) == 0
  checks[["policy_6_required_scripts"]] <- list(
    passed  = scripts_ok,
    message = if (scripts_ok)
      sprintf("Policy 6 PASS: All %d required pipeline scripts present", length(required_scripts))
    else
      sprintf("Policy 6 FAIL: Missing scripts: %s", paste(missing_scripts, collapse=", "))
  )
  
  # ── Summary ───────────────────────────────────────────────
  all_passed <- all(sapply(checks, function(c) isTRUE(c$passed)))
  for (chk in checks) {
    if (chk$passed) log_info(chk$message) else log_warn(chk$message)
  }
  log_info("=== Policy check complete — {ifelse(all_passed,'ALL PASSED','FAILURES DETECTED')} ===")
  
  list(all_passed = all_passed, checks = checks)
}

cat("[policy_check] infra/policies/model_policy_check.R loaded — run_policy_check() ready.\n")