# tests/integration/test_pipeline_e2e.R
library(testthat)
library(here)
library(DBI)

suppressMessages({
  source(here::here("global_config.R"))
  source(here::here("api", "plumber.R"))
})
if (exists(".restore_test_singleton", envir = .GlobalEnv, inherits = FALSE)) {
  get(".restore_test_singleton", envir = .GlobalEnv)()
}

TEST_HADM_ID <- 800023822L

test_that("End-to-end: /predict is deterministic and trace_ids are unique", {
  p1 <- predict_core(TEST_HADM_ID)
  p2 <- predict_core(TEST_HADM_ID)
  expect_equal(p1$predicted_risk, p2$predicted_risk)
  expect_false(p1$trace_id == p2$trace_id)
  expect_equal(round(p1$predicted_risk, 3), 0.793)
})

test_that("End-to-end: /predict and /explain return same risk score", {
  p <- predict_core(TEST_HADM_ID)
  e <- explain_core(TEST_HADM_ID)
  expect_equal(p$predicted_risk, e$predicted_risk)
})

test_that("End-to-end: /rag/summary retrieves clinically relevant guidelines", {
  r <- rag_summary_core(TEST_HADM_ID, icd_families = "I50,J44")
  top_docs <- r$retrieval_debug$doc_name
  expect_true("hf_discharge_protocol" %in% top_docs)
  expect_true("copd_readmission_prevention" %in% top_docs)
  expect_true(nchar(r$summary) > 50)
})

test_that("End-to-end: each /predict call writes its own audit row", {
  con      <- get_db_connection()
  n_before <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  
  predict_core(TEST_HADM_ID)
  predict_core(TEST_HADM_ID)
  
  n_after <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  expect_equal(n_after, n_before + 2)
})

test_that("End-to-end: all governance tables remain intact", {
  con    <- get_db_connection()
  tables <- c("ingest_metadata","feature_registry","model_registry",
              "fairness_reports","rag_chunks","rag_index_metadata",
              "llm_call_log","predictions_audit")
  for (tbl in tables) {
    n <- DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s", tbl))$n
    expect_gt(n, 0, label = sprintf("%s has rows", tbl))
  }
})