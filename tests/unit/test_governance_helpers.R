# tests/unit/test_governance_helpers.R
library(testthat)
library(here)
library(DBI)

suppressMessages({
  source(here::here("global_config.R"))
  source(here::here("r_scripts", "governance_helpers.R"))
})
if (exists(".restore_test_singleton", envir = .GlobalEnv, inherits = FALSE)) {
  get(".restore_test_singleton", envir = .GlobalEnv)()
}

test_that("write_predictions_audit() appends a row with correct fields", {
  con    <- get_db_connection()
  n_pre  <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  
  write_predictions_audit(con,
                          trace_id = "test-trace-unit-gov-001", patient_id_hash = "hash_patient",
                          input_hash = "hash_input", model_version = "v_test", risk_score = 0.75,
                          risk_tier = "high", explanation_snippet = "n_prior_admissions above median",
                          env = "synthetic", created_by = "test_runner"
  )
  
  n_post <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  expect_equal(n_post, n_pre + 1)
  
  row <- DBI::dbGetQuery(con,
                         "SELECT * FROM predictions_audit WHERE trace_id = 'test-trace-unit-gov-001'")
  expect_equal(nrow(row), 1)
  expect_equal(row$model_version, "v_test")
  expect_equal(row$risk_score, 0.75)
  
  DBI::dbExecute(con, "DELETE FROM predictions_audit WHERE trace_id = 'test-trace-unit-gov-001'")
})

test_that("write_predictions_audit() stores patient_id as hash, not raw id", {
  con <- get_db_connection()
  
  write_predictions_audit(con,
                          trace_id = "test-trace-unit-gov-002",
                          patient_id_hash = digest::digest("908646"),
                          input_hash = "hash_input", model_version = "v_test", risk_score = 0.5,
                          risk_tier = "medium", explanation_snippet = "test", env = "synthetic",
                          created_by = "test_runner"
  )
  
  row <- DBI::dbGetQuery(con,
                         "SELECT * FROM predictions_audit WHERE trace_id = 'test-trace-unit-gov-002'")
  expect_false(grepl("908646", row$patient_id_hash))
  expect_true(nchar(row$patient_id_hash) > 10)
  
  DBI::dbExecute(con, "DELETE FROM predictions_audit WHERE trace_id = 'test-trace-unit-gov-002'")
})

test_that("write_ingest_metadata() rejects PHI in non-production mode", {
  skip_if(Sys.getenv("ENV_MODE") == "production")
  con <- get_db_connection()
  expect_error(
    write_ingest_metadata(con, source = "test", table_name = "test_tbl",
                          rows = 100L, data_hash = "abc", sensitivity_label = "PHI",
                          start_ts = Sys.time(), end_ts = Sys.time()),
    regexp = "Ingest rejected"
  )
})

test_that("write_feature_registry() is idempotent by (feature_name, version)", {
  con <- get_db_connection()
  for (i in 1:2) {
    write_feature_registry(con, "test_feature_gov_unit", "v_test_gov",
                           "this visit only", "test_script.R",
                           "No leakage risk", "test_runner")
  }
  rows <- DBI::dbGetQuery(con,
                          "SELECT * FROM feature_registry WHERE feature_name='test_feature_gov_unit' AND version='v_test_gov'")
  expect_equal(nrow(rows), 1)
  DBI::dbExecute(con, "DELETE FROM feature_registry WHERE feature_name='test_feature_gov_unit'")
})

test_that("policy check passes with current project state", {
  source(here::here("infra", "policies", "model_policy_check.R"))
  if (exists(".restore_test_singleton", envir = .GlobalEnv, inherits = FALSE)) {
    get(".restore_test_singleton", envir = .GlobalEnv)()
  }
  result <- run_policy_check()
  expect_true(result$all_passed)
  expect_equal(length(result$checks), 6)
})