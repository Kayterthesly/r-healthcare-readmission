# ============================================================
# global_config.R
# r-healthcare-readmission — Unified Workflow
# ============================================================
#
# PURPOSE:
#   Single data access layer for the entire pipeline.
#   No script ever connects to a database directly.
#   All scripts call get_db_connection() from this file.
#
# STORAGE PROVIDER:
#   Works identically against MinIO (local), Cloudflare R2,
#   Backblaze B2, or AWS S3 — only .Renviron values change.
#   Currently configured for: MinIO (local Docker).
#
# USAGE:
#   source("global_config.R")
#   con <- get_db_connection()
#   register_cloud_tables(con)
#   dbGetQuery(con, "SELECT * FROM syn_person LIMIT 10")
#   close_db_connection(con)
# ============================================================

library(DBI)
library(duckdb)
library(here)
library(logger)

# ── Read environment settings ─────────────────────────────
ENV_MODE       <- Sys.getenv("ENV_MODE",               "synthetic")
CLOUD_LABEL    <- Sys.getenv("CLOUD_PROVIDER_LABEL",   "Unknown provider")
CLOUD_ENDPOINT <- Sys.getenv("CLOUD_ENDPOINT",         "")
CLOUD_KEY_ID   <- Sys.getenv("CLOUD_ACCESS_KEY_ID",    "")
CLOUD_SECRET   <- Sys.getenv("CLOUD_SECRET_ACCESS_KEY","")
CLOUD_BUCKET   <- Sys.getenv("CLOUD_BUCKET_NAME",      "healthcare-rag-synth")
CLOUD_USE_SSL  <- as.logical(Sys.getenv("CLOUD_USE_SSL", "TRUE"))
CLOUD_REGION   <- Sys.getenv("CLOUD_REGION",           "auto")
DB_PATH        <- Sys.getenv("DB_PATH_SYNTHETIC",
                             here::here("data", "local_query_cache.duckdb"))

log_threshold(Sys.getenv("LOG_LEVEL", "INFO"))
log_info("[global_config] ENV_MODE: {ENV_MODE}")
log_info("[global_config] Storage provider: {CLOUD_LABEL}")

# ── Project metadata ─────────────────────────────────────
PROJECT_META <- list(
  name        = "Healthcare Readmission Forecasting Pipeline",
  version     = Sys.getenv("PIPELINE_VERSION", "1.0.0"),
  data_schema = "MIMIC-IV MEDS → OMOP-compatible",
  cloud       = CLOUD_LABEL
)

# ── MAIN FUNCTION: get_db_connection() ───────────────────
get_db_connection <- function(mode = ENV_MODE) {
  
  if (mode %in% c("synthetic", "staging")) {
    log_info("[DB] Opening local DuckDB at: {DB_PATH}")
    db_abs <- if (grepl("^(/|[A-Za-z]:)", DB_PATH)) DB_PATH else file.path(here::here(), DB_PATH)
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_abs)
    
    tryCatch({
      dbExecute(con, "INSTALL httpfs;")
      dbExecute(con, "LOAD httpfs;")
      log_info("[DB] httpfs extension loaded.")
    }, error = function(e) {
      log_warn("[DB] httpfs already installed: {e$message}")
      dbExecute(con, "LOAD httpfs;")
    })
    
    if (nchar(CLOUD_ENDPOINT) > 0) {
      # Strip protocol — DuckDB wants host:port only,
      # SSL is controlled separately via s3_use_ssl
      bare_endpoint <- gsub("^https?://", "", CLOUD_ENDPOINT)
      
      dbExecute(con, sprintf("SET s3_endpoint='%s';", bare_endpoint))
      dbExecute(con, sprintf("SET s3_access_key_id='%s';", CLOUD_KEY_ID))
      dbExecute(con, sprintf("SET s3_secret_access_key='%s';", CLOUD_SECRET))
      dbExecute(con, sprintf("SET s3_use_ssl=%s;",
                             ifelse(CLOUD_USE_SSL, "true", "false")))
      dbExecute(con, sprintf("SET s3_region='%s';", CLOUD_REGION))
      dbExecute(con, "SET s3_url_style='path';")
      log_info("[DB] Object storage configured: {CLOUD_LABEL} ({bare_endpoint}, ssl={CLOUD_USE_SSL})")
    } else {
      log_warn("[DB] CLOUD_ENDPOINT not set. Cloud queries will fail.")
    }
    
    return(con)
    
  } else if (mode == "production") {
    log_info("[DB] Connecting to production PostgreSQL...")
    return(DBI::dbConnect(
      RPostgres::Postgres(),
      dbname   = Sys.getenv("PROD_DB_NAME"),
      host     = Sys.getenv("PROD_DB_HOST"),
      port     = as.integer(Sys.getenv("PROD_DB_PORT")),
      user     = Sys.getenv("PROD_DB_USER"),
      password = Sys.getenv("PROD_DB_PASS")
    ))
    
  } else {
    stop(sprintf(
      "[DB] Unknown ENV_MODE: '%s'. Use: synthetic | staging | production",
      mode
    ))
  }
}

# ── register_cloud_tables() ───────────────────────────────
register_cloud_tables <- function(con, bucket = CLOUD_BUCKET) {
  tables <- c(
    "syn_person", "syn_visit", "syn_condition", "syn_measurement",
    "canonical_person", "canonical_visit", "canonical_condition", "canonical_measurement",
    "features_v1"
    # syn_discharge_notes added later — Stage 6, generated via ellmer
  )
  for (tbl in tables) {
    s3_path <- sprintf("s3://%s/%s.parquet", bucket, tbl)
    sql <- sprintf(
      "CREATE OR REPLACE VIEW %s AS SELECT * FROM '%s';",
      tbl, s3_path
    )
    tryCatch({
      dbExecute(con, sql)
      log_info("[DB] Registered view: {tbl} → {s3_path}")
    }, error = function(e) {
      log_warn("[DB] Could not register {tbl}: {e$message}")
    })
  }
  invisible(NULL)
}

# ── close_db_connection() ─────────────────────────────────
close_db_connection <- function(con) {
  if (!is.null(con) && DBI::dbIsValid(con)) {
    DBI::dbDisconnect(con, shutdown = TRUE)
    log_info("[DB] Connection closed.")
    Sys.sleep(0.05)   # Windows DuckDB file-lock release (documented: Stage 0 notes)
    gc()
  }
}

log_info("[global_config] Ready. Call get_db_connection() to connect.")
log_info("[global_config] Project: {PROJECT_META$name} v{PROJECT_META$version}")