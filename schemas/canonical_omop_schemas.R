# ============================================================
# schemas/canonical_omop_schemas.R
# r-healthcare-readmission — Stage 2
# ============================================================
# Canonical schemas for the 4 core tables, plus the generic
# cast_and_validate() and check_referential_integrity()
# functions every ingest job runs through.
#
# Rule: no table reaches the canonical zone without passing
# both functions. Fail fast and loud on drift, never silently
# coerce and continue.
# ============================================================

library(dplyr)
library(lubridate)

# ── Schema definitions: column name → required R type ────
canonical_person_schema <- list(
  subject_id          = "integer",
  gender              = "character",
  age_at_first_admit  = "numeric",
  is_deceased         = "character"
)

canonical_visit_schema <- list(
  subject_id      = "integer",
  hadm_id         = "integer",
  admit_time      = "POSIXct",
  discharge_time  = "POSIXct",
  los_days        = "numeric",
  admission_type  = "character",
  insurance       = "character",
  language        = "character",
  marital_status  = "character",
  race            = "character",
  readmit_30d     = "integer"
)

canonical_condition_schema <- list(
  subject_id   = "integer",
  hadm_id      = "integer",
  icd_version  = "character",
  icd_code     = "character",
  dx_time      = "POSIXct"
)

canonical_measurement_schema <- list(
  subject_id     = "integer",
  hadm_id        = "integer",
  lab_itemid     = "character",
  lab_unit       = "character",
  lab_time       = "POSIXct",
  numeric_value  = "numeric",
  text_value     = "character"
)

# ── not_null_cols: which columns may NEVER be NA ──────────
not_null_map <- list(
  person      = c("subject_id"),
  visit       = c("subject_id", "hadm_id", "admit_time", "discharge_time", "readmit_30d"),
  condition   = c("subject_id", "hadm_id", "icd_code"),
  measurement = c("subject_id", "hadm_id")
)

# ── cast_and_validate(): the one function every table runs
#    through before it's allowed into the canonical zone ────
cast_and_validate <- function(df, schema, not_null_cols = character(0), table_name = "table") {
  
  required_cols <- names(schema)
  missing_cols  <- setdiff(required_cols, names(df))
  if (length(missing_cols) > 0) {
    stop(sprintf("[%s] Missing required columns: %s",
                 table_name, paste(missing_cols, collapse = ", ")))
  }
  
  for (col in required_cols) {
    target_type <- schema[[col]]
    df[[col]] <- switch(target_type,
                        "character" = as.character(df[[col]]),
                        "integer"   = as.integer(df[[col]]),
                        "numeric"   = as.numeric(df[[col]]),
                        "Date"      = as.Date(df[[col]]),
                        "POSIXct"   = as.POSIXct(df[[col]]),
                        "logical"   = as.logical(df[[col]]),
                        stop(sprintf("[%s] Unknown target type '%s' for column '%s'",
                                     table_name, target_type, col))
    )
  }
  
  for (col in not_null_cols) {
    n_na <- sum(is.na(df[[col]]))
    if (n_na > 0) {
      stop(sprintf("[%s] Null values in required column '%s': %d row(s)",
                   table_name, col, n_na))
    }
  }
  
  df[, required_cols]   # canonical column order, drop anything extra
}

# ── check_referential_integrity(): a child row's foreign key
#    must exist in the parent table — fail loud if not ──────
check_referential_integrity <- function(child_df, child_key, parent_df, parent_key,
                                        child_name, parent_name) {
  orphans <- setdiff(unique(child_df[[child_key]]), unique(parent_df[[parent_key]]))
  if (length(orphans) > 0) {
    stop(sprintf("[REFERENTIAL INTEGRITY] %d '%s' value(s) in %s have no matching '%s' in %s",
                 length(orphans), child_key, child_name, parent_key, parent_name))
  }
  invisible(TRUE)
}

cat("[schemas] canonical_omop_schemas.R loaded — 4 schemas, cast_and_validate(), check_referential_integrity() ready.\n")