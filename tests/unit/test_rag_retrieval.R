# tests/unit/test_rag_retrieval.R
library(testthat)
library(here)
library(dplyr)

suppressMessages(source(here::here("rag", "llm_wrapper.R")))
if (exists(".restore_test_singleton", envir = .GlobalEnv, inherits = FALSE)) {
  get(".restore_test_singleton", envir = .GlobalEnv)()
}

test_that("TF-IDF index loads correctly", {
  index_path <- here::here("rag", "tfidf_index_v1.rds")
  expect_true(file.exists(index_path))
  index <- readRDS(index_path)
  expect_named(index, c("matrix","vocab","idf","chunk_ids","icd_tags"), ignore.order = TRUE)
  expect_gt(nrow(index$matrix), 0)
  expect_gt(length(index$vocab), 100)
})

test_that("Heart failure patient retrieves HF guideline as top chunk", {
  index      <- readRDS(here::here("rag", "tfidf_index_v1.rds"))
  con_db     <- get_db_connection()
  all_chunks <- DBI::dbGetQuery(con_db, "SELECT chunk_id, doc_name, chunk_text, icd_tags FROM rag_chunks")
  
  hf_profile <- list(
    risk_pct = 79.3, top_feature_names = c("n_prior_admissions","pct_high_risk_dx"),
    icd_families = c("I50"), condition_terms = c("heart failure"),
    los_days = 6.5, n_prior_admissions = 8
  )
  
  retrieved <- retrieve_chunks(hf_profile, index, all_chunks, k = 3)
  expect_equal(nrow(retrieved), 3)
  expect_equal(retrieved$doc_name[1], "hf_discharge_protocol")
  expect_true(all(retrieved$combined > 0))
})

test_that("COPD patient retrieves COPD guideline in top 2", {
  index      <- readRDS(here::here("rag", "tfidf_index_v1.rds"))
  con_db     <- get_db_connection()
  all_chunks <- DBI::dbGetQuery(con_db, "SELECT chunk_id, doc_name, chunk_text, icd_tags FROM rag_chunks")
  
  copd_profile <- list(
    risk_pct = 60.0, top_feature_names = c("n_prior_admissions"),
    icd_families = c("J44"), condition_terms = c("COPD"),
    los_days = 4.0, n_prior_admissions = 3
  )
  
  retrieved <- retrieve_chunks(copd_profile, index, all_chunks, k = 3)
  expect_true("copd_readmission_prevention" %in% retrieved$doc_name[1:2])
})

test_that("generate_discharge_summary() returns full Section 12 contract", {
  result <- generate_discharge_summary(
    subject_id = 908646, hadm_id = 800023822, predicted_risk = 0.793,
    top_feature_names = c("n_prior_admissions","pct_high_risk_dx"),
    icd_families = c("I50","J44"), los_days = 6.5, n_prior_admissions = 8
  )
  expect_named(result, c("summary_text","citations","retrieval_debug",
                         "trace_id","model_version","index_version"), ignore.order = TRUE)
  expect_match(result$trace_id, "^[0-9a-f]{8}-")
  expect_true(nchar(result$summary_text) > 50)
  expect_equal(nrow(result$retrieval_debug$top_chunks), 3)
})

test_that("Combined retrieval scores are in 0-1 range", {
  index      <- readRDS(here::here("rag", "tfidf_index_v1.rds"))
  con_db     <- get_db_connection()
  all_chunks <- DBI::dbGetQuery(con_db, "SELECT chunk_id, doc_name, chunk_text, icd_tags FROM rag_chunks")
  profile <- list(risk_pct=50, top_feature_names=c("n_prior_admissions"),
                  icd_families=c("I50"), condition_terms=c("heart failure"),
                  los_days=3, n_prior_admissions=2)
  retrieved <- retrieve_chunks(profile, index, all_chunks, k=5)
  expect_true(all(retrieved$combined >= 0))
  expect_true(all(retrieved$combined <= 1))
})