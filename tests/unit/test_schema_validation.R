# tests/unit/test_schema_validation.R
library(testthat)
library(here)
library(dplyr)

source(here::here("schemas", "canonical_omop_schemas.R"))

test_that("cast_and_validate() passes a correctly-typed table", {
  df <- data.frame(
    subject_id = 1L, gender = "F", age_at_first_admit = 55.2, is_deceased = "no",
    stringsAsFactors = FALSE
  )
  result <- cast_and_validate(df, canonical_person_schema,
                              not_null_cols = not_null_map$person, "person")
  expect_equal(nrow(result), 1)
  expect_equal(class(result$subject_id), "integer")
  expect_equal(class(result$gender), "character")
  expect_equal(class(result$age_at_first_admit), "numeric")
})

test_that("cast_and_validate() coerces character to integer", {
  df <- data.frame(subject_id = "42", gender = "M",
                   age_at_first_admit = 70.0, is_deceased = "no",
                   stringsAsFactors = FALSE)
  result <- cast_and_validate(df, canonical_person_schema,
                              not_null_cols = not_null_map$person, "person")
  expect_equal(result$subject_id, 42L)
  expect_type(result$subject_id, "integer")
})

test_that("cast_and_validate() stops on missing required column", {
  df <- data.frame(gender = "F", age_at_first_admit = 55.0, is_deceased = "no",
                   stringsAsFactors = FALSE)
  expect_error(
    cast_and_validate(df, canonical_person_schema,
                      not_null_cols = not_null_map$person, "person"),
    regexp = "Missing required columns"
  )
})

test_that("cast_and_validate() stops on NA in not_null column", {
  df <- data.frame(subject_id = NA_integer_, gender = "F",
                   age_at_first_admit = 55.0, is_deceased = "no",
                   stringsAsFactors = FALSE)
  expect_error(
    cast_and_validate(df, canonical_person_schema,
                      not_null_cols = not_null_map$person, "person"),
    regexp = "Null values in required column"
  )
})

test_that("cast_and_validate() drops extra columns", {
  df <- data.frame(subject_id = 1L, gender = "F", age_at_first_admit = 55.0,
                   is_deceased = "no", extra_col = "should_be_dropped",
                   stringsAsFactors = FALSE)
  result <- cast_and_validate(df, canonical_person_schema,
                              not_null_cols = not_null_map$person, "person")
  expect_false("extra_col" %in% names(result))
  expect_equal(names(result), names(canonical_person_schema))
})

test_that("check_referential_integrity() passes when all FK values present in parent", {
  parent <- data.frame(subject_id = 1:3)
  child  <- data.frame(subject_id = c(1L, 2L, 3L, 1L))
  expect_true(check_referential_integrity(child, "subject_id", parent, "subject_id",
                                          "child", "parent"))
})

test_that("check_referential_integrity() stops on orphan FK", {
  parent <- data.frame(subject_id = 1:2)
  child  <- data.frame(subject_id = c(1L, 2L, 99L))
  expect_error(
    check_referential_integrity(child, "subject_id", parent, "subject_id",
                                "child", "parent"),
    regexp = "REFERENTIAL INTEGRITY"
  )
})