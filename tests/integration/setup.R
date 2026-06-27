# tests/integration/setup.R
setwd(here::here())
suppressMessages(source(here::here("global_config.R")))

.TEST_CON <- get_db_connection()
register_cloud_tables(.TEST_CON)

assign(".TEST_CON", .TEST_CON, envir = .GlobalEnv)
assign("get_db_connection", function() get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE), envir = .GlobalEnv)
assign("close_db_connection", function(con) invisible(NULL), envir = .GlobalEnv)

assign(".restore_test_singleton", function() {
  .tc <- get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE)
  assign("get_db_connection", function() .tc, envir = .GlobalEnv)
  assign("close_db_connection", function(con) invisible(NULL), envir = .GlobalEnv)
}, envir = .GlobalEnv)

withr::defer({
  con <- tryCatch(get(".TEST_CON", envir = .GlobalEnv, inherits = FALSE), error = function(e) NULL)
  if (!is.null(con)) { try(DBI::dbDisconnect(con, shutdown = TRUE), silent=TRUE); Sys.sleep(1); gc() }
}, teardown_env())