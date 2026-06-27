# tests/unit/test_api_core.R
library(testthat)
library(here)

# Source the API — this re-sources global_config.R which overwrites
# our singleton overrides. Restore them immediately after.
suppressMessages(source(here::here("api", "plumber.R")))
if (exists(".restore_test_singleton", envir = .GlobalEnv, inherits = FALSE)) {
  get(".restore_test_singleton", envir = .GlobalEnv)()
}

test_that("/health returns correct structure", {
  h <- health_core()
  expect_named(h, c("status","model_version","index_version","timestamp","endpoints"))
  expect_equal(h$status, "ok")
  expect_equal(h$model_version, "v3")
  expect_match(h$timestamp, "\\d{4}-\\d{2}-\\d{2}")
})

test_that("/predict returns all required contract fields", {
  p <- predict_core(800023822L)
  expect_named(p, c("trace_id","model_version","hadm_id","subject_id",
                    "predicted_risk","risk_tier","threshold","flagged",
                    "top_drivers","disclaimer"), ignore.order = TRUE)
  expect_match(p$trace_id, "^[0-9a-f]{8}-")
  expect_true(p$predicted_risk >= 0 && p$predicted_risk <= 1)
  expect_true(p$risk_tier %in% c("high","medium","low"))
  expect_type(p$flagged, "logical")
})

test_that("/predict predicted_risk matches known value for test patient", {
  p <- predict_core(800023822L)
  expect_equal(round(p$predicted_risk, 3), 0.793)
})

test_that("/predict correctly classifies above-threshold patient as high", {
  p <- predict_core(800023822L)
  expect_true(p$flagged)
  expect_equal(p$risk_tier, "high")
})

test_that("/predict produces unique trace_id on each call", {
  p1 <- predict_core(800023822L)
  p2 <- predict_core(800023822L)
  expect_false(p1$trace_id == p2$trace_id)
})

test_that("/explain returns all required contract fields", {
  e <- explain_core(800023822L)
  expect_named(e, c("trace_id","model_version","hadm_id","predicted_risk",
                    "risk_tier","explanation","permutation_rank","disclaimer"),
               ignore.order = TRUE)
  expect_length(e$explanation, 5)
  first_feat <- e$explanation[[1]]
  expect_named(first_feat, c("feature","value","median","delta","direction","note"),
               ignore.order = TRUE)
  expect_true(first_feat$direction %in% c("above_median","below_median"))
})

test_that("/predict writes to predictions_audit", {
  con      <- get_db_connection()
  n_before <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  
  predict_core(800023822L)
  
  n_after <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM predictions_audit")$n
  expect_gt(n_after, n_before)
})

test_that("/predict stops on invalid hadm_id", {
  expect_error(predict_core(999999999L))
})