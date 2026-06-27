# tests/unit/setup.R
# ============================================================
# Runs ONCE before all unit test files in this directory.
# Two problems fixed here:
#
# 1. Working directory: test_dir() changes WD to the test
#    directory, breaking relative paths. setwd(here::here())
#    restores the project root.
#
# 2. Windows DuckDB file locking: rapid sequential open/close
#    cycles in the same R process trigger Windows file-handle
#    retention, causing "cannot open file" errors on the second
#    open. Fix: open ONE connection at session start, override
#    get_db_connection() to always return it, override
#    close_db_connection() to be a no-op. Single connection
#    stays open for the entire test session.
# ============================================================

setwd(here::here())
suppressMessages(source(here::here("global_config.R")))

.TEST_CON <- get_db_connection()
register_cloud_tables(.TEST_CON)

assign(".TEST_CON", .TEST_CON, envir = .GlobalEnv)

assign("get_db_connection", function() {
  get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE)
}, envir = .GlobalEnv)

assign("close_db_connection", function(con) invisible(NULL), envir = .GlobalEnv)

# Called after each test file that re-sources global_config.R
# (which would overwrite our overrides)
assign(".restore_test_singleton", function() {
  .tc <- get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE)
  assign("get_db_connection", function() .tc, envir = .GlobalEnv)
  assign("close_db_connection", function(con) invisible(NULL), envir = .GlobalEnv)
}, envir = .GlobalEnv)

withr::defer({
  con <- tryCatch(get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE), error = function(e) NULL)
  if (!is.null(con)) {
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
    Sys.sleep(1); gc()
  }
}, teardown_env())