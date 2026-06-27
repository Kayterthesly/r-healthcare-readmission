# ============================================================
# api/run_api.R
# ============================================================
# Run this script to start the Plumber API on port 8080.
# In RStudio: open api/plumber.R and click "Run API", OR
# run this script in a SEPARATE R session (not the Console
# where you run verification — the server blocks the console).
# ============================================================

library(plumber)
library(here)

log_path <- here::here("logs", sprintf("api_%s.log", format(Sys.time(), "%Y%m%d_%H%M%S")))

pr <- plumber::plumb(here::here("api", "plumber.R"))
cat(sprintf("[API] Starting on http://127.0.0.1:8080\n"))
cat(sprintf("[API] Swagger UI: http://127.0.0.1:8080/__docs__/\n"))
cat(sprintf("[API] Log: %s\n", log_path))
pr$run(host = "127.0.0.1", port = 8080)