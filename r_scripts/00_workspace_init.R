# ============================================================
# r_scripts/00_workspace_init.R
# r-healthcare-readmission — Unified Workflow
# ============================================================
# Run this first in every new session.
# ============================================================

library(renv)
library(logger)
library(here)

log_threshold(Sys.getenv("LOG_LEVEL", "INFO"))
log_info("=== WORKSPACE INITIALIZATION ===")
log_info("Project root: {here::here()}")
log_info("ENV_MODE: {Sys.getenv('ENV_MODE', 'synthetic')}")

log_info("Checking renv environment...")
tryCatch({
  renv::restore(prompt = FALSE)
  log_info("renv environment: OK")
}, error = function(e) {
  log_warn("renv restore failed: {e$message}")
})

log_info("Verifying project directories...")
required_dirs <- c(
  "r_scripts", "schemas", "models/artifacts",
  "rag", "api", "dashboard", "infra/k8s",
  "tests/unit", "tests/integration",
  "data/meds_raw", "data/temp_synth",
  "logs", "docs", "notes"
)
for (d in required_dirs) {
  full_path <- here::here(d)
  if (!dir.exists(full_path)) {
    dir.create(full_path, recursive = TRUE)
    log_warn("Created missing directory: {d}")
  }
}
log_info("Directory check: complete")

log_info("Checking critical files...")
critical_files <- c(
  "global_config.R", ".Renviron", ".env", "renv.lock",
  "docker-compose.yml", "schemas/canonical_omop_schemas.R"
)
all_files_ok <- TRUE
for (f in critical_files) {
  fp <- here::here(f)
  if (file.exists(fp)) {
    log_info("  ✅ {f}")
  } else {
    log_error("  ❌ MISSING: {f}")
    all_files_ok <- FALSE
  }
}

log_info("Loading global_config.R...")
tryCatch({
  source(here::here("global_config.R"), local = new.env())
  log_info("global_config.R: OK")
}, error = function(e) {
  log_error("global_config.R failed: {e$message}")
  all_files_ok <- FALSE
})

log_info("Testing DuckDB + cloud storage connection...")
tryCatch({
  source(here::here("global_config.R"))
  con <- get_db_connection()
  result <- dbGetQuery(con, "SELECT 42 AS test_val")
  log_info("DuckDB query test: {result$test_val}")
  close_db_connection(con)
  log_info("DuckDB connection: OK")
}, error = function(e) {
  log_error("DuckDB connection failed: {e$message}")
})

if (all_files_ok) {
  log_info("=== WORKSPACE READY ✅ ===")
} else {
  log_error("=== WORKSPACE HAS ISSUES ❌ ===")
}