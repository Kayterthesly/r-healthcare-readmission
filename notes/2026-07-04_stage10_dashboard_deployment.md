# ✍️ Handwritten Notes — r-healthcare-readmission
## Stage 10: Dashboard & Cloud Deployment

**Date:** 2026-07-01 – 2026-07-04
**Author:** Kingsley Akenu (@Kayterthesly / KAIZEN 改善)
**Status:** ✅ VERIFIED COMPLETE — Full production stack live

---

```
╔══════════════════════════════════════════════════════════════╗
║  STAGE 10 BRIEF                                               ║
╠══════════════════════════════════════════════════════════════╣
║  Status:   ✅ COMPLETE — All four services live               ║
║  Goal:     Deploy the full pipeline to the cloud:             ║
║            Backblaze B2 (storage), Railway (Plumber API),     ║
║            shinyapps.io (Shiny dashboard), and wire them      ║
║            together into one coherent production stack.       ║
║  Output:   Live REST API · Live dashboard · Live cloud        ║
║            storage · Public GitHub repo                       ║
║  URLs:     API: r-healthcare-readmission-production.up.       ║
║                 railway.app                                   ║
║            Dashboard: e9yw5n-kayterthesly.shinyapps.io/       ║
║                       healthcare-readmission-pipeline         ║
║            Code: github.com/Kayterthesly/                     ║
║                  r-healthcare-readmission                     ║
╚══════════════════════════════════════════════════════════════╝
```

### Why This Stage Exists

A pipeline that only runs on the developer's laptop isn't a production
pipeline — it's a prototype. Stage 10 closes that gap. Everything
built across Stages 0–9 (synthesis, modeling, RAG, API, monitoring,
71 tests) gets deployed to real cloud infrastructure so that any
device with internet access can query live predictions, view governance
data, and interact with the full system. This is what distinguishes a
portfolio project from a folder of scripts.

### Layman Explanation

> A restaurant doesn't prove its food is good by cooking in a test
> kitchen forever. At some point the doors open, real customers walk
> in, and the kitchen has to perform under real conditions. Stage 10
> is opening day. The menu (Shiny dashboard), the kitchen (Railway
> API), the supply chain (Backblaze B2), and the recipe book
> (GitHub) are all live, connected, and working together for the
> first time in the real world.

---

## 🐛 PROBLEMS FACED & SOLUTIONS

### Problem 1 — Cloudflare R2 billing bug

**What happened:**
The original architecture specified Cloudflare R2 as the S3-compatible
cloud storage provider. During account creation, the "Add R2
subscription" button got stuck in an infinite loop — confirmed via
web search as a known, recurring Cloudflare billing bug.

**Solution:**
Pivoted to **Backblaze B2** — also S3-compatible, free for 10GB,
no billing bug. Swapping required editing 6 lines in `.Renviron`
and zero lines of pipeline code — exactly what the provider-agnostic
architecture from Stage 0 was designed to support.

**Rule to remember:**
> Build storage integrations to an interface, not an implementation.
> `global_config.R` reads provider, endpoint, and credentials from
> environment variables — the pipeline code never names "Backblaze"
> or "Cloudflare" directly.

---

### Problem 2 — Railway: renv source compilation timeout

**What happened:**
First two Railway Dockerfile builds timed out after exactly 20
minutes with `renv::restore()` compiling all 197 packages from
source. `renv.lock` pointed to `cloud.r-project.org` (source
packages on Linux) and specified R 4.5.2, which mismatched the
`rocker/r-ver:4.4.2` Docker base image.

**Root cause:**
Two compounding issues:
1. Source package compilation for 197 packages = ~25 minutes
2. R version mismatch (4.5.2 vs 4.4.2) caused `renv` to abort

**Solution:**
Bypassed `renv` entirely in Docker. Installed packages directly from
**Posit Package Manager binary mirror** (Ubuntu Noble binaries —
pre-compiled `.tar.gz` files, ~2 minutes total). Five `RUN` groups
preserve Docker layer caching.

**Rule to remember:**
> `renv.lock` generated on Windows is not directly portable to Linux
> Docker without the Posit PM binary mirror override. The fastest
> cross-platform Docker R setup: skip renv, install from
> `packagemanager.posit.co/cran/__linux__/noble/latest`.

---

### Problem 3 — Railway: `.Rprofile` activating renv at container startup

**What happened:**
After the binary install fix, Docker image built correctly. But at
container startup: `here() starts at /app/api` then
`cannot open file '.../global_config.R'`. Packages were installed
but the API crashed immediately.

**Root cause:**
`Rscript` reads `.Rprofile` by default before executing any code.
The project's `.Rprofile` contains `source("renv/activate.R")`.
Even though renv wasn't installed in Docker, `renv/activate.R` was
copied into the image (via `COPY . .`), reconfigured `.libPaths()`
to point ONLY at `renv/library/` (empty in this image), and hid
the system library where `install.packages()` had actually put the
packages. Result: `library(plumber)` — "no package called 'plumber'".

**Solution:**
`.dockerignore` excluding `.Rprofile`, `renv/`, and `renv.lock`
from the Docker build context entirely. Defense-in-depth:
`ENV RENV_CONFIG_AUTOLOADER_ENABLED=FALSE` in Dockerfile.

**Rule to remember:**
> `.dockerignore` is as important as `.gitignore` for R projects.
> A project `.Rprofile` that activates `renv` will silently hijack
> `.libPaths()` in any container where it's copied — even when renv
> itself was not installed. Exclude it at the build context level.

---

### Problem 4 — Railway: `rocker/r-ver:4.4.2` is Ubuntu 24.04 (Noble), not 22.04 (Jammy)

**What happened:**
After excluding `.Rprofile`, packages installed and were visible.
But at container startup: `libicui18n.so.70: cannot open shared
object file`. The `stringi` package (required by `stringr`) crashed
immediately.

**Root cause:**
The Posit PM binaries were fetched from the `jammy` (Ubuntu 22.04)
mirror, which compiles `stringi` against ICU 70 (`libicui18n.so.70`).
`rocker/r-ver:4.4.2` actually runs Ubuntu 24.04 (Noble), which only
has ICU 74 (`libicui18n.so.74`). Railway's own diagnostic confirmed:
"Update the Posit Package Manager URL from `jammy/latest` to
`noble/latest`."

**Solution:**
Changed one word in the Dockerfile: `jammy` → `noble`. Noble binaries
compiled against ICU 74 match the Noble system. Build time unchanged.

**Rule to remember:**
> Always verify the Ubuntu version of your Docker base image before
> choosing a Posit PM binary mirror. `rocker/r-ver:4.4.2` = Noble
> (24.04). `rocker/r-ver:4.3.x` = Jammy (22.04). ICU version
> mismatch = silent crash at first `library()` call.

---

### Problem 5 — Railway: `library(tidymodels)` missing at startup

**What happened:**
After the Noble fix, `here()` anchored correctly to `/app`, packages
loaded, but the API crashed on line 19: `Error in library(tidymodels):
there is no package called 'tidymodels'`.

**Root cause:**
`api/plumber.R` called `library(tidymodels)` (the meta-package
wrapper). The Dockerfile installed tidymodels' components individually
(`parsnip`, `recipes`, `rsample`, etc.) but not the meta-package
wrapper itself, which has its own namespace entry.

**Solution:**
Added `tidymodels` to Dockerfile Group 4. Also replaced
`library(tidymodels)` in `api/plumber.R` with the two packages
the API actually needs at runtime: `library(recipes)` and
`library(parsnip)`. Both fixes applied.

---

### Problem 6 — Railway: `here()` anchoring at `/app/api` instead of `/app`

**What happened:**
`plumber::plumb('api/plumber.R')` changes the working directory to
`api/` before sourcing the file. `here::here()` anchored to
`/app/api/` — so `source(here::here("global_config.R"))` looked for
`/app/api/global_config.R`, which doesn't exist.

**Solution:**
Three-layer defense:
1. `.here` file at project root — `here` traverses up from `/app/api/`
   and finds `/app/.here`, anchoring to `/app/`
2. Dockerfile CMD: explicit `setwd('/app')` before `plumb()`
3. `api/plumber.R` top: `if (file.exists('/app')) setwd('/app')`

**Rule to remember:**
> `plumber::plumb()` changes the working directory to the file's
> containing folder before sourcing. Any `here::here()` calls in
> the sourced file resolve from that new WD. Fix: `.here` anchor
> file at project root + explicit `setwd()` in CMD.

---

### Problem 7 — RAG chunks missing from Railway DuckDB

**What happened:**
`/rag/summary` returned "RAG summary unavailable" even after the
API started correctly. `rag_chunks` table was empty on Railway
because `data/local_query_cache.duckdb` is gitignored — Railway
gets a fresh, empty DuckDB on every deploy.

**Solution:**
Added startup check in `api/plumber.R`: if `rag_chunks` has fewer
than 16 rows, `source("rag/rag_indexing.R")` to rebuild the
16-chunk TF-IDF index. Runs once at container startup, takes ~5
seconds, and every subsequent `/rag/summary` call finds a populated
index.

**Rule to remember:**
> Anything stored in a gitignored local database must be either:
> (a) rebuilt at startup from source files that ARE in the repo, or
> (b) backed up to external storage and restored at startup.
> Governance DuckDB = gitignored + stateful. RAG index = gitignored
> but rebuildable from `rag/guidelines/` (committed). Use option (a).

---

### Problem 8 — Dashboard: Shiny WD changes, DuckDB path breaks

**What happened:**
`shiny::runApp("dashboard/app.R")` changes WD to `dashboard/`.
`DB_PATH = "data/local_query_cache.duckdb"` resolves to
`dashboard/data/...` — file not found. Every DuckDB call in the
local dashboard showed "cannot open the connection."

**Solution:**
`setwd(here::here())` at the very top of `dashboard/app.R` (before
any `source()` calls), and updated `global_config.R`'s
`get_db_connection()` to always prepend the absolute project root
if the path is relative:
```r
db_abs <- if (grepl("^(/|[A-Za-z]:)", DB_PATH)) DB_PATH
          else file.path(here::here(), DB_PATH)
```

---

### Problem 9 — shinyapps.io: wrong `app.R` deployed (local vs deploy version)

**What happened:**
First shinyapps.io deployment showed `cannot open file
'.../global_config.R'` — the local version of `dashboard/app.R`
was deployed, not the static-bundle deploy version.

**Solution:**
Two separate app files:
- `dashboard/app.R` (local) — uses DuckDB + live `*_core()` calls
- `dashboard/app.R` (deploy) — uses `data/deploy_bundle.rds` + Railway API calls

For deployment, the deploy version is written directly to
`dashboard/app.R`, deployed to shinyapps.io, then the local version
can be restored. A `.dockerignore`-equivalent approach: maintain
both versions explicitly.

---

### Problem 10 — Dashboard: httr2 defaults to GET, Plumber expects POST

**What happened:**
Dashboard showed live risk scores from `/predict` initially... then
"API unavailable." Turned out `/predict` was actually being called
as GET (httr2 default), and Plumber's `@post` decorator was returning
404. The dashboard appeared to work on the first attempt coincidentally.

**Solution:**
Added `req_method("POST")` to every `call_api()` in the dashboard:
```r
resp <- request(paste0(RAILWAY_URL, path)) |>
  req_method("POST") |>
  req_timeout(60) |>
  req_perform()
```

**Rule to remember:**
> `httr2::req_perform()` defaults to GET. Plumber endpoints decorated
> with `@post` only respond to POST. Always specify `req_method()`
> explicitly — never rely on httr2's default for non-GET endpoints.

---

### Problem 11 — Dashboard: `resp_body_json()` returning lists, not data.frames

**What happened:**
After fixing the POST method, risk scores appeared correctly but
the drivers chart showed an error. `resp_body_json()` (without
`simplifyVector = TRUE`) returns deeply nested R lists, not data.frames.
`as.data.frame(e$explanation)` crashed on the list structure.

**Solution:**
Added `simplifyVector = TRUE` to `resp_body_json()`. Then replaced
`as.data.frame()` with `sapply()` for robust extraction regardless
of httr2 parsing structure:
```r
df <- data.frame(
  feature = sapply(expl, function(x) as.character(x$feature)),
  delta   = sapply(expl, function(x) as.numeric(x$delta))
)
```

---

### Problem 12 — Gemini HTTP 429 (quota exhausted)

**What happened:**
All `/rag/summary` calls returned the template fallback with
"GEMINI UNAVAILABLE". Deploy logs confirmed:
`WARN [RAG] Gemini API error: HTTP 429 Too Many Requests`.

**Root cause:**
HTTP 429 means the key IS valid and IS accepted by Google's servers
— the free tier daily quota (1M tokens/day) was exhausted from
repeated testing. Note: key format `AQ.Ab8...` (not `AIza...`) is
Google AI Studio's newer key format — still valid.

**Status:**
Template fallback is working correctly — retrieving the right
guidelines and producing clinically sensible recommendations with
guideline citations. The architecture (RAG retrieval + governance
contract + trace_id) is complete and correct. Gemini live output
requires quota reset (daily at midnight Pacific) or a paid tier
upgrade (~$0.075/1M tokens for Gemini Flash).

---

## 1. 📌 What I Did

- Signed up for and configured Backblaze B2 (9 files, 82 MB)
- Updated `.Renviron` for B2 (6 environment variable changes)
- Re-ran Stages 2 and 3 against B2 — canonical tables and
  `features_v1` uploaded without code changes
- Verified B2 live: `features_v1 rows from B2: 41,358`
- Built `Dockerfile` (7 iterations, each fixing one new issue)
- Built `railway.toml` (health check config)
- Built `.dockerignore` (critical fix for renv autoloader)
- Deployed to Railway, diagnosed and fixed 8 startup failures
- Built `dashboard/app.R` (local version, 5 tabs, all working)
- Built `dashboard/app_deploy.R` → `dashboard/app.R` (deploy version)
- Generated `dashboard/data/deploy_bundle.rds` (static data snapshot)
- Deployed to shinyapps.io — all 5 tabs working
- Fixed httr2 GET/POST issue (req_method("POST"))
- Fixed resp_body_json parsing (simplifyVector=TRUE + sapply)
- Fixed RAG startup rebuild (source rag_indexing.R if empty)
- Added B2 warm-up at API startup
- Built recruiter-facing README (433 lines, badges, Mermaid diagram,
  performance tables, API reference)
- Built non-technical presentation (502 lines, 20 slides, 5 phases)
- Pushed final commit to GitHub

---

## 2. 🎯 Why I Did It

A portfolio project that only runs locally proves you can write code.
A portfolio project that's deployed, tested in production, and
accessible from any browser proves you can ship software. The gap
between those two is where most data science projects stay. Stage 10
crossed it.

---

## 3. 🗣️ Layman Explanation

> Same opening-day analogy as the brief: cooking in a test kitchen
> vs. opening the restaurant. Every previous stage was the test
> kitchen. This stage opened the doors.

---

## 4. 📚 New Terms Learned

| Term | Meaning |
|------|---------|
| Backblaze B2 | S3-compatible cloud object storage. Free tier: 10GB storage, 1GB/day download. Endpoint format: `s3.us-east-005.backblazeb2.com` |
| `.dockerignore` | Same concept as `.gitignore`, but for Docker build context. Files listed here are never copied into the image — even if `COPY . .` is used |
| Posit Package Manager (binary mirror) | A package repository that serves pre-compiled R packages for specific Linux distributions. Jammy (Ubuntu 22.04) vs Noble (Ubuntu 24.04) are different mirrors |
| ICU (International Components for Unicode) | A system library that `stringi` (and therefore `stringr`) depends on. ICU 70 = Ubuntu 22.04. ICU 74 = Ubuntu 24.04. Version mismatch = crash at library load |
| `renv::activate.R` / `.Rprofile` | The renv autoloader that runs every time R starts. In a Docker container with no renv library, it silently redirects `.libPaths()` to an empty folder |
| `req_method("POST")` | `httr2` function that explicitly sets the HTTP method. Without it, `req_perform()` defaults to GET — Plumber `@post` endpoints return 404 |
| `simplifyVector = TRUE` | `resp_body_json()` argument that converts JSON arrays to R vectors/data.frames instead of nested lists |
| PSI (Population Stability Index) | A metric that measures how much the distribution of model input/output scores has shifted between training and production. PSI < 0.10 = stable. |
| `withr::defer()` | Registers cleanup code that runs when the current scope ends — even if an error occurs. Used in `tests/unit/setup.R` for DuckDB singleton teardown |
| Deploy bundle (`deploy_bundle.rds`) | A pre-computed snapshot of all governance data, saved as a single RDS file and bundled with the shinyapps.io deployment. Eliminates the need for DuckDB or MinIO at runtime |

---

## 5. 🗺️ Workflow Map

```
LOCAL DEVELOPMENT
─────────────────
dashboard/app.R (local)
  ↓ setwd(here::here()) → DuckDB singleton
  ↓ get_db_connection() → local_query_cache.duckdb
  ↓ *_core() functions → live model predictions
  ↓ shiny::runApp() → http://127.0.0.1:PORT

SHINYAPPS.IO DEPLOYMENT
────────────────────────
dashboard/app.R (deploy version)
  ↓ readRDS("data/deploy_bundle.rds") → static governance data
  ↓ call_api() → req_method("POST") → Railway API (httr2)
  ↓ resp_body_json(simplifyVector=TRUE) → parse response
  ↓ rsconnect::deployApp() → shinyapps.io
  → https://e9yw5n-kayterthesly.shinyapps.io/...

RAILWAY API DEPLOYMENT
───────────────────────
Dockerfile (7 iterations):
  1. rocker/r-ver:4.4.2 (Ubuntu 24.04 Noble)
  2. apt-get: system libs + libicu-dev
  3. noble/latest Posit PM binary mirror
  4. install.packages() in 5 cached groups
  5. .dockerignore excludes .Rprofile + renv/
  6. COPY . . (now safe — renv autoloader excluded)
  7. CMD: setwd('/app') → source() → plumb() → run()

Startup sequence in Railway container:
  source('global_config.R')          ← B2 connection configured
  source('governance_helpers.R')     ← 7 write functions
  source('rag/llm_wrapper.R')        ← Gemini function detected
  readRDS('models/artifacts/...')    ← xgboost_v3 loaded
  → B2 warm-up (features_v1 count)
  → RAG rebuild if rag_chunks < 16
  plumb('api/plumber.R')             ← 4 endpoints live
  pr$run(host='0.0.0.0', port=$PORT) ← healthcheck succeeds

BACKBLAZE B2 STORAGE
─────────────────────
.Renviron (6 vars):
  CLOUD_ENDPOINT=https://s3.us-east-005.backblazeb2.com
  CLOUD_ACCESS_KEY_ID=005cb61f8efe17c0000000001
  CLOUD_REGION=us-east-005
  ...
→ 9 Parquet files, 82 MB
→ Queryable via DuckDB httpfs from any environment
```

---

## 6. 🔢 Important Calculations / Rules

**Deployment timeline:**
- Backblaze B2 upload: ~10 minutes (9 files, 82 MB)
- Railway Docker build: ~3-4 minutes (binary packages)
- Railway deploy: ~30-60 seconds (container start + B2 warm-up)
- shinyapps.io deploy: ~3-5 minutes (bundle upload + package install)

**Docker build cache structure (5 groups):**
```
Group 1: Foundation (here, logger, uuid, digest, jsonlite, tibble, dplyr, ...)
Group 2: Database + cloud (DBI, duckdb, arrow, paws)
Group 3: ML core (Matrix, glmnet, xgboost, ROSE)
Group 4: tidymodels (tidymodels, hardhat, parsnip, recipes, rsample, ...)
Group 5: API + LLM (plumber, ellmer, httr2)
```
Each group is a separate `RUN` layer — unchanged groups are cached.

**Final stack verification:**
```
curl https://r-healthcare-readmission-production.up.railway.app/health
{"status":["ok"],"model_version":["v3"],"index_version":["v1"],...}

curl -X POST ".../predict?hadm_id=800040634"
{"predicted_risk":[0.6921],"risk_tier":["high"],"flagged":[true],...}
```

```
Rule 1: .dockerignore is as important as .gitignore for R projects —
        .Rprofile must never enter a Docker image that bypasses renv
Rule 2: Always verify Ubuntu version of Docker base image before
        choosing Posit PM mirror: 4.4.2 = Noble, 4.3.x = Jammy
Rule 3: req_method("POST") must be explicit in httr2 — never assume
        the default
Rule 4: resp_body_json(simplifyVector=TRUE) for data.frame-like JSON;
        use sapply() as fallback for mixed structures
Rule 5: gitignored local DuckDB must be rebuilt at startup from
        committed source files — never assume it persists across deploys
Rule 6: shinyapps.io environment variables must be set via R console
        for this account — website UI does not work
Rule 7: Railway free tier sleeps after 30 min inactivity — first
        request after sleep takes 20-40s; 60s timeout in dashboard
Rule 8: Gemini HTTP 429 = quota exhausted (key is valid) — template
        fallback is the correct graceful degradation, not an error
```

---

## 7. 🤔 Confusions / Questions to Revisit

**Q: Why does Gemini return 429 even with a valid key?**
The free Gemini tier (Google AI Studio) has a daily token quota.
Multiple test runs during development exhausted it. The key is valid —
HTTP 429 is "too many requests," not 401 (unauthorized) or 403
(forbidden). Fix: wait for daily reset or upgrade to pay-as-you-go
($0.075/1M tokens for Gemini Flash — essentially free at this scale).

**Q: Why is the local dashboard different from the shinyapps.io version?**
The local version reads directly from DuckDB and calls `*_core()`
functions in the same R session. The deploy version reads from a
pre-computed bundle (no DuckDB needed) and calls Railway via HTTP.
Two different environments require two different connection strategies.

---

## 8. ⚓ Memory Anchor

> **Deployment is debugging in a new environment.**
> Every bug fixed in Stages 0–9 was debugging in a local R session.
> Deployment adds a new environment (Linux container) with different
> library versions, different filesystem paths, different startup
> sequences, and different networking. Each deployment failure was
> a new environment teaching a new lesson — ICU versions, renv
> autoloaders, HTTP methods, DuckDB persistence. The debugging
> discipline is the same; the environment is new.

---

## 9. ❓ Self-Test Questions

1. Why does `.Rprofile` cause R package installation to become
   invisible in a Docker container that bypassed renv?
2. What is the difference between Ubuntu Jammy and Ubuntu Noble,
   and why does it matter for R package binaries?
3. Why does `httr2::req_perform()` return a 404 from a Plumber
   endpoint even when the URL and endpoint name are correct?
4. Why is `data/local_query_cache.duckdb` gitignored, and what
   two strategies exist for making its data available in Railway?
5. What does HTTP 429 confirm about a Gemini API key, and what
   does it NOT mean?
6. Why does shinyapps.io need a static bundle rather than a live
   DuckDB connection, while Railway can use DuckDB directly?
7. What is the purpose of the `deploy_bundle.rds` file, and what
   data does it contain?
8. Why are there 5 separate `RUN` groups in the Dockerfile rather
   than one `RUN Rscript -e "install.packages(c(...))"` block?
9. Why must `req_method("POST")` be explicit in httr2?
10. What is the difference between `setwd(here::here())` in
    `dashboard/app.R` (local) and `if(file.exists('/app')) setwd('/app')`
    in `api/plumber.R` (Railway)?

---

## 10. 🔄 KAIZEN Improvement Note (改善)

> Stage 10 took approximately 30 Dockerfile iterations across 8
> distinct failure modes — each one a new environment-specific
> lesson. The correct meta-lesson: **never assume a working local
> environment maps directly to a cloud container**. The next version
> of this deployment should start with a CI test that builds the
> Docker image locally (`docker build -t test .`) before pushing to
> Railway. Catching ICU mismatches, renv autoloader interference,
> and missing system libraries locally takes 3 minutes; catching
> them in Railway takes 3 minutes + a push + a build queue. Build
> locally first, always.
>
> A second improvement: the deploy bundle (`deploy_bundle.rds`)
> is generated manually before each shinyapps.io deployment. An
> automated update — triggered by the GitHub Actions CI pipeline
> whenever `model_registry` or `fairness_reports` change — would
> ensure the dashboard always reflects the current model state
> without manual intervention.

---

## 🏆 PROJECT COMPLETE

```
╔══════════════════════════════════════════════════════════════╗
║  HEALTHCARE READMISSION FORECASTING PIPELINE                  ║
║  ALL 10 STAGES VERIFIED COMPLETE                              ║
╠══════════════════════════════════════════════════════════════╣
║  Stages 0–9:   Built, tested, documented (71/0 tests)         ║
║  Stage 10:     Deployed to 4 live cloud services              ║
╠══════════════════════════════════════════════════════════════╣
║  GitHub:   github.com/Kayterthesly/r-healthcare-readmission   ║
║  API:      r-healthcare-readmission-production.up.railway.app ║
║  Storage:  Backblaze B2, s3.us-east-005.backblazeb2.com       ║
║  Dashboard: e9yw5n-kayterthesly.shinyapps.io/                 ║
║             healthcare-readmission-pipeline                   ║
╠══════════════════════════════════════════════════════════════╣
║  Model:    xgboost_v3 — Recall 0.885, AUC-ROC 0.566          ║
║  Tests:    71 passing, 0 failures                              ║
║  Governance: 8 tables, 100+ rows, all append-only             ║
╠══════════════════════════════════════════════════════════════╣
║  KAIZEN (改善) — Continuous, honest improvement.              ║
║  Every limitation disclosed. Every failure diagnosed.          ║
║  Every stage documented. Every test green.                    ║
╚══════════════════════════════════════════════════════════════╝
```

*Stage 10 verified complete — 2026-07-04.*
*Full production stack live. Pipeline complete.*
*Built by Kingsley Akenu (@Kayterthesly — KAIZEN 改善), Lagos, Nigeria.*
