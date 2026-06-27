# ============================================================
# r_scripts/02_ingest_and_cast.R
# r-healthcare-readmission — Stage 2
# ============================================================
# Reads each syn_* table from MinIO, casts + validates against
# its canonical schema, checks referential integrity against
# its parent table, writes canonical_*.parquet back to MinIO,
# and records an ingest_metadata governance entry per table.
# ============================================================

library(here); library(DBI); library(arrow); library(paws)
library(dplyr); library(digest); library(logger)

source(here::here("global_config.R"))
source(here::here("schemas", "canonical_omop_schemas.R"))
source(here::here("r_scripts", "governance_helpers.R"))

log_info("=== 02_ingest_and_cast.R: STAGE 2 ===")

# ── Pull all 4 raw synthetic tables live from MinIO ───────
con <- get_db_connection()
register_cloud_tables(con)

person_raw      <- dbGetQuery(con, "SELECT * FROM syn_person")
visit_raw       <- dbGetQuery(con, "SELECT * FROM syn_visit")
condition_raw   <- dbGetQuery(con, "SELECT * FROM syn_condition")
measurement_raw <- dbGetQuery(con, "SELECT * FROM syn_measurement")

close_db_connection(con)
log_info("Pulled 4 raw tables live from MinIO: {nrow(person_raw)}/{nrow(visit_raw)}/{nrow(condition_raw)}/{nrow(measurement_raw)} rows")

# ── Cast + validate each table against its canonical schema ──
canonical_person <- cast_and_validate(
  person_raw, canonical_person_schema, not_null_map$person, "person")

canonical_visit <- cast_and_validate(
  visit_raw, canonical_visit_schema, not_null_map$visit, "visit")

canonical_condition <- cast_and_validate(
  condition_raw, canonical_condition_schema, not_null_map$condition, "condition")

canonical_measurement <- cast_and_validate(
  measurement_raw, canonical_measurement_schema, not_null_map$measurement, "measurement")

log_info("All 4 tables passed cast_and_validate()")

# ── Referential integrity — fail loud if anything is orphaned ──
check_referential_integrity(canonical_visit, "subject_id", canonical_person, "subject_id",
                            "visit", "person")
check_referential_integrity(canonical_condition, "hadm_id", canonical_visit, "hadm_id",
                            "condition", "visit")
check_referential_integrity(canonical_measurement, "hadm_id", canonical_visit, "hadm_id",
                            "measurement", "visit")

log_info("All referential integrity checks passed")

# ── Write canonical Parquet locally, upload, record governance ──
dir.create(here::here("data", "temp_synth"), showWarnings = FALSE)
out_dir <- here::here("data", "temp_synth")

canonical_tables <- list(
  canonical_person      = canonical_person,
  canonical_visit       = canonical_visit,
  canonical_condition   = canonical_condition,
  canonical_measurement = canonical_measurement
)

s3_client <- paws::s3(config = list(
  credentials = list(creds = list(
    access_key_id     = Sys.getenv("CLOUD_ACCESS_KEY_ID"),
    secret_access_key = Sys.getenv("CLOUD_SECRET_ACCESS_KEY"))),
  endpoint = Sys.getenv("CLOUD_ENDPOINT"),
  region   = Sys.getenv("CLOUD_REGION", "us-east-1")
))

local_con <- get_db_connection()   # for ingest_metadata writes — local DuckDB

for (tbl_name in names(canonical_tables)) {
  start_ts <- Sys.time()
  df       <- canonical_tables[[tbl_name]]
  
  fp <- file.path(out_dir, paste0(tbl_name, ".parquet"))
  arrow::write_parquet(df, fp)
  
  s3_client$put_object(
    Bucket = Sys.getenv("CLOUD_BUCKET_NAME"),
    Key    = paste0(tbl_name, ".parquet"),
    Body   = readBin(fp, "raw", n = file.info(fp)$size)
  )
  
  end_ts    <- Sys.time()
  data_hash <- digest::digest(df)
  
  write_ingest_metadata(
    con = local_con, source = "r_scripts/01_synthetic_mimic_generator.R",
    table_name = tbl_name, rows = nrow(df), data_hash = data_hash,
    sensitivity_label = "SYNTHETIC", start_ts = start_ts, end_ts = end_ts
  )
  
  log_info("✅ {tbl_name}: {nrow(df)} rows → uploaded → ingest_metadata recorded (hash: {substr(data_hash,1,8)}...)")
}

close_db_connection(local_con)

# ── Cleanup local temp ─────────────────────────────────────
file.remove(list.files(out_dir, pattern = "canonical_.*\\.parquet$", full.names = TRUE))
log_info("=== STAGE 2 COMPLETE — canonical zone live in MinIO ===")