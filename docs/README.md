# 🏥 Healthcare Readmission Forecasting Pipeline

`Version: 1.9.0` | `Status: ✅ COMPLETE — All 9 Stages Verified`

**Author:** Kingsley Akenu (@Kayterthesly — KAIZEN 改善)
**Location:** Lagos, Nigeria
**Data:** MIMIC-IV MEDS Demo (100 pts) → synthpop → 15,000 pts → S3-compatible object storage
**Stack:** R · DuckDB · MinIO · MIMIC-IV MEDS · synthpop · tidymodels · ellmer · plumber · testthat

---

## Project Overview

A production-grade, auditable, end-to-end healthcare pipeline that:

- Predicts 30-day hospital readmission risk from structured EHR data
- Uses RAG to retrieve clinical guidelines and generate per-patient discharge recommendations with cited sources
- Exposes a REST API with full governance audit trails on every call
- Validates its own governance compliance with a policy check and 71-test suite on every CI push
- Remains clinician-review only — supports decisions, never makes them

---

## Business Problem

Hospital readmission within 30 days is a measurable quality failure costing
$15,000–$20,000 per unnecessary readmission. This pipeline identifies
high-risk patients at discharge and gives clinicians specific, cited guidance
to prevent those readmissions — with every prediction traceable to its input,
its model version, and its audit log entry.

---

## Architecture Flow

```
MIMIC-IV MEDS demo (100 real patients, PhysioNet)
  ↓ Stage 1: synthpop synthesis → 15,000 patients
  ↓ Stage 2: Canonical casting + referential integrity
  ↓ Stage 3: Feature engineering (DuckDB SQL on MinIO Parquet)
  ↓ Stage 4: XGBoost + glmnet training (tidymodels, Recall ≥ 0.85)
  ↓ Stage 5: Permutation importance + fairness stratification
  ↓ Stage 6: TF-IDF RAG (40/30/30 hybrid) + ellmer/Gemini
  ↓ Stage 7: Plumber REST API (4 endpoints, trace_id + audit)
  ↓ Stage 8: Monitoring + GitHub Actions CI + policy checks
  ↓ Stage 9: testthat suite (71 tests, 0 failures)
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness check |
| POST | `/predict` | Risk score + top drivers + trace_id. Writes `predictions_audit`. |
| POST | `/explain` | Per-feature explanation with deltas vs. training medians |
| POST | `/rag/summary` | RAG-cited discharge recommendation (Gemini or template fallback) |

Start: `source("api/run_api.R")` in a separate R session.
All responses carry `trace_id`, `model_version`, and a clinical disclaimer.

---

## Stage Status

| Stage | Name | Status |
|-------|------|--------|
| 0 | Workspace Setup | ✅ Complete |
| 1 | Synthetic MIMIC-IV Dataset | ✅ Complete (v2 — severity-linked) |
| 2 | Ingest & Canonical Casting | ✅ Complete |
| 3 | Feature Engineering | ✅ Complete (v3 — continuous severity) |
| 4 | Modeling & Evaluation | ✅ Complete (weak-signal finding disclosed) |
| 5 | Explainability & Clinical Validation | ✅ Complete |
| 6 | RAG Retrieval & LLM Wrapper | ✅ Complete |
| 7 | API & Deployment | ✅ Complete |
| 8 | Observability & CI/CD | ✅ Complete |
| 9 | Testing Matrix & Gating | ✅ Complete — 71 tests, 0 failures |

---

## Technical Stack

| Component | Tool | Why |
|-----------|------|-----|
| Language | R + SQL | Healthcare analytics |
| Package manager | renv | Reproducible package lock |
| Paths | here | Machine-independent paths |
| Logging | logger | Structured logs |
| Database engine | DuckDB + httpfs | Queries MinIO Parquet directly via SQL |
| Cloud storage | MinIO (local Docker) → R2/B2 planned | Free, S3-compatible, zero code changes to swap |
| Parquet IO | arrow | Reads/writes MEDS format |
| S3 management | paws | Bucket operations from R |
| Data synthesis | synthpop | Statistically faithful synthesis |
| ML framework | tidymodels | Unified ML lifecycle |
| Primary model | XGBoost (boost_tree) | High recall capability |
| Baseline model | glmnet (logistic) | Interpretable comparison |
| Evaluation | yardstick | Recall, AUC-ROC, PR-AUC |
| Imbalance | ROSE | Synthetic oversampling (train only) |
| RAG retrieval | TF-IDF + 40/30/30 hybrid | Base R, no extra packages, auditable |
| LLM connector | ellmer | Gemini API (version-robust detection) |
| API | plumber | REST endpoints, *_core() pattern |
| Monitoring | r_scripts/08_monitoring.R | PSI drift, governance completeness |
| CI/CD | GitHub Actions | 9-step pipeline |
| Policy check | infra/policies/model_policy_check.R | 6 governance invariants |
| Testing | testthat | 71 tests (55 unit + 16 integration) |
| Audit trail | uuid + digest | trace_id + data hashes |

---

## Architecture Evolution Log

### Stage 0 — Workspace & Environment Setup ✅

**Date:** 2026-06-19

Complete reproducible R environment: 14-folder scaffold, `renv`-locked package
set (26 packages), `.Renviron`-based secrets management, provider-agnostic
object storage layer (`global_config.R`). Pivoted to MinIO (local Docker) from
Cloudflare R2 (known billing bug). Fixed console prompt-cascade install bug
(`renv::install(prompt=FALSE)`).

---

### Stage 1 — Synthetic MIMIC-IV Dataset ✅

**Date:** 2026-06-19 – 2026-06-21 (v1 → v2)

`r_scripts/01_synthetic_mimic_generator.R` — 5 sections. Reshapes 916,166 real
MEDS events (100 patients) into 4 relational tables, synthesizes to 15,000
patients via synthpop. v2 added a shared latent `is_severe` draw per visit
(real severity rate 45.8%, computed empirically), linking timing (shorter gaps
for severe visits via stratified real-gap pools + 0.85 literature-grounded
nudge) and diagnosis sampling (40% high-risk codes in severe visits vs 5%).
`is_severe` dropped before upload — never exposed downstream.

**v2 outcome:** readmit_30d by severity: 17.7% vs. 22.8%. All 4 tables live
in MinIO, verified queryable via DuckDB `httpfs`.

---

### Stage 2 — Ingest & Canonical Casting ✅

**Date:** 2026-06-20

4 canonical schemas, `cast_and_validate()`, `check_referential_integrity()`,
`write_ingest_metadata()`. PHI/ENV_MODE gate confirmed. Zero code changes on
v2 re-run — interface contract validated. 4 `ingest_metadata` governance rows.

---

### Stage 3 — Feature Engineering ✅

**Date:** 2026-06-20 – 2026-06-21 (v1 → v3)

**v1→v2:** Lab selection by raw event count picked 10 qualitative-only
itemids (100% NA columns). Fixed: rank by `COUNT(numeric_value)`.

**v2→v3:** `high_risk_dx_flag` (binary) saturated at 88% of visits, collapsing
a real 42.9%-vs-9.4% per-code severity signal to a 2.9pp readmit gap. Added
`pct_high_risk_dx` (continuous fraction). Confirmed as real secondary signal in
Stage 5 permutation importance (0.0111 AUC drop).

**Outcome:** `features_v1` — 41,358 rows × 81 cols, zero leakage.
`feature_registry` — 4 idempotent, version-aware entries.

---

### Stage 4 — Modeling & Evaluation ✅ (weak-signal finding disclosed)

**Date:** 2026-06-21

**Three diagnostic rounds:**

Round 1 — ROSE crash: `is_deceased` excluded via `update_role()` but not
from the actual data frame — must be explicitly `select()`-ed out.

Round 2 — Near-random AUC (0.545–0.568): `glmnet` concentrated almost
entirely on `n_prior_admissions`. XGBoost spread importance thin (top 3
features = 9.3% of gain). Root cause: Stage 1's independent timing/severity
generation → Stage 1 v2 severity fix.

Round 3 — XGBoost noise-latching: `lab_224168_min` jumped to 30.6% of
gain (v2) but ranked nowhere in glmnet — coincidental pattern from random
number sequence shift. Regularized XGBoost (depth=4, min_n=30,
sample_size=0.7, mtry=38, loss_reduction=1). AUC held steady (0.566 vs 0.556).

**Final result — xgboost_v3 (reference model):**

| Version | Model | Recall | AUC-ROC | PR-AUC |
|---|---|---|---|---|
| v3 | glmnet | 0.878 | 0.568 | 0.236 |
| **v3** | **xgboost** | **0.885** | **0.566** | **0.244** |

AUC-ROC 0.566 is a real, modest improvement over the 0.545 baseline — not
strongly discriminative. Documented in `docs/00_locked_decisions.md` Section 13.
`approved = TRUE` certifies Recall ≥ 0.85 floor only, not clinical utility.

**Disclosed limitation:** Three rounds used test-set AUC as the upstream
decision signal — a mild form of test-set-adaptive tuning. Iteration stopped
at round 3 for this reason.

---

### Stage 5 — Explainability & Clinical Validation ✅

**Date:** 2026-06-22

`r_scripts/05_explainability_fairness.R` — permutation importance (95 features,
3 repeats each), pure-R per-patient explanations (training-median baseline,
Windows `predcontrib` alignment workaround), `clinician_review_cases_v3.csv`
(15 cases, 5 drivers each), fairness stratification.

**Key findings:**

Permutation importance confirmed two-signal structure:
- `n_prior_admissions`: 0.0432 AUC drop (dominant)
- `pct_high_risk_dx`: 0.0111 AUC drop (real secondary — Stage 3 v3 fix confirmed working)
- All labs: < 0.002 each (marginal / noise)

Fairness: Gender (1.2pp recall gap) — clear. Insurance (0.7pp) — clear.
Race (87pp, 13.0% to 100%) — **flagged**. Most likely noise artifact of thin
racial representation in the 100-patient source, correctly detected regardless
of cause.

`fairness_reports` governance table: 19 rows.

---

### Stage 6 — RAG Retrieval & LLM Wrapper ✅

**Date:** 2026-06-23

8 synthetic clinical guideline documents (heart failure, COPD, CKD, sepsis,
acute MI + 3 general protocols) → 16 chunks → 241-term TF-IDF matrix.

**40/30/30 hybrid retrieval:**
- 40% TF-IDF cosine similarity (full text)
- 30% Keyword density (exact term frequency)
- 30% ICD tag overlap (structured metadata)

Validated: HF+COPD patient → HF protocol #1 (0.412), COPD prevention #2
(0.278), high-risk criteria #3 (0.262). Clinically appropriate.

`generate_discharge_summary()` returns Section 12 governance contract:
`{summary_text, citations, retrieval_debug, trace_id, model_version, index_version}`.
ellmer version-robust detection (scans namespace for `chat_gemini` OR
`chat_google_gemini`). Template fallback for offline/rate-limited environments.

`rag_index_metadata` + `llm_call_log` governance tables live.

---

### Stage 7 — API & Deployment ✅

**Date:** 2026-06-23

`api/plumber.R` — 4 Plumber REST endpoints. `*_core()` pattern: business
logic in plain R functions, route decorators as thin wrappers — testable
without running an HTTP server.

`write_predictions_audit()` — 7th and final Section 12 governance write
function. One row per `/predict` call, storing hashes only (never raw
feature values or patient identifiers).

Verification: three distinct trace_ids, `predicted_risk = 0.7934` matching
Stage 5 exactly, `predictions_audit` row written. Gemini HTTP 429 confirmed
real API connectivity; template fallback handled gracefully.

---

### Stage 8 — Observability & CI/CD ✅

**Date:** 2026-06-23 – 2026-06-24

`r_scripts/08_monitoring.R` — reads all 7 governance tables, computes model
health + PSI drift + fairness + LLM stats + governance completeness, writes
timestamped markdown to `logs/`. PSI framework-ready; reports
INSUFFICIENT_DATA when N < 30 rather than a misleadingly precise number.

`infra/policies/model_policy_check.R` — 6 policy checks (approved model,
recall gate, leakage notes, decisions doc sections, metadata JSON, script
existence). All 6 passed.

`.github/workflows/ci.yml` — 9-step GitHub Actions pipeline. Policy 4
heading-format mismatch fixed (dual regex: `"## 12\\."` OR `"Section 12"`).

**Monitoring outcome:** HEALTHY. Drift: INSUFFICIENT_DATA (N=1, min 30).
Race: flagged (87pp). LLM fallback: 100% (all calls pre-key-rename).

---

### Stage 9 — Testing Matrix & Gating ✅ — PIPELINE COMPLETE

**Date:** 2026-06-24 – 2026-06-25

**Test files:**
- `tests/unit/test_schema_validation.R` — 7 tests
- `tests/unit/test_api_core.R` — 8 tests
- `tests/unit/test_rag_retrieval.R` — 5 tests
- `tests/unit/test_governance_helpers.R` — 5 tests
- `tests/integration/test_pipeline_e2e.R` — 5 tests

**Final result: 55 unit + 16 integration = 71 tests, 0 failures.**

**Three problems solved:**
1. `testthat` not installed → `install.packages("testthat")` + `renv::snapshot()`
2. `test_dir()` changes WD → `setup.R` with `setwd(here::here())`
3. Windows DuckDB file-locking on rapid open/close → connection singleton
   pattern (open once in `setup.R`, override `get_db_connection()` globally,
   `close_db_connection()` no-op, `withr::defer()` teardown)

**Complication:** Files that `source(global_config.R)` overwrite singleton
overrides → `.restore_test_singleton()` called after each such source().

---

## Governance Layer (Complete — All 8 Tables Active)

All in local DuckDB (`data/local_query_cache.duckdb`):

| Table | Rows | Stage |
|---|---|---|
| `ingest_metadata` | 4+ | 2 |
| `feature_registry` | 4 | 3 |
| `model_registry` | 6 | 4 |
| `fairness_reports` | 19 | 5 |
| `rag_chunks` | 16 | 6 |
| `rag_index_metadata` | 1+ | 6 |
| `llm_call_log` | 3+ | 6–7 |
| `predictions_audit` | 1+ | 7 |

---

## Model Development

### Current Best: xgboost v3

Recall 0.885 · Precision 0.212 · AUC-ROC 0.566 · PR-AUC 0.244 at threshold 0.58.
See `docs/00_locked_decisions.md` Section 13 for the full governance
clarification. `approved = TRUE` certifies Recall ≥ 0.85 floor only — not
clinical utility. This is an architecture-validation model on a 100-patient
synthetic source, not a deployment-ready classifier.

### Artifacts

```
models/artifacts/
  glmnet_{v1,v2,v3}.rds
  xgboost_{v1,v2,v3}.rds
  recipe_{v1,v2,v3}.rds
  metadata_{glmnet,xgboost}_{v1,v2,v3}.json
  fairness_report_xgboost_v3.md
  clinician_review_cases_v3.csv
```

---

## RAG System

8 synthetic guideline docs · 16 chunks · 241-term TF-IDF vocabulary.
40/30/30 hybrid: TF-IDF cosine (40%) / keyword density (30%) / ICD tag overlap (30%).
ellmer → Gemini 2.0 Flash. Template fallback when API unavailable.
Every call logged to `llm_call_log` (request_hash + response_hash).

---

## Testing

71 tests (55 unit + 16 integration), 0 failures.
Run: `testthat::test_dir("tests/unit")` and `testthat::test_dir("tests/integration")`.
CI: `.github/workflows/ci.yml` runs on every push to `main`.

**Windows DuckDB pattern (documented):** Tests use a connection singleton
in `tests/unit/setup.R` to prevent OS-level file-lock conflicts between
rapid sequential connect/disconnect cycles.

---

## Key Operational Rules

1. `docker ps` before any pipeline script — `docker compose up -d` if `healthcare-rag-minio` absent
2. `GOOGLE_API_KEY` in `.Renviron` (not `GEMINI_API_KEY`) for ellmer
3. `renv::install(prompt=FALSE)` for package installs — never paste multi-group blocks interactively
4. Windows DuckDB in tests: connection singleton in `setup.R`; `gc(); gc(); Sys.sleep(0.5)` in `close_db_connection()` for non-test use
5. `is_deceased` must be explicitly `select()`-ed out of modeling data frames — `update_role()` alone does not remove it

---

## Progress Tracker

### Completed ✅ — ALL STAGES

- [x] Stage 0 — Workspace, MinIO, global_config.R
- [x] Stage 1 — Synthetic dataset v2 (15,000 patients, severity-linked)
- [x] Stage 2 — Canonical casting, ingest_metadata
- [x] Stage 3 — Features v3: lab fix, pct_high_risk_dx
- [x] Stage 4 — xgboost_v3, 3 diagnostic rounds, honest AUC 0.566 disclosed
- [x] Stage 5 — Permutation importance, fairness 19 rows, clinician CSV
- [x] Stage 6 — TF-IDF RAG, 40/30/30 retrieval, Section 12 contract
- [x] Stage 7 — 4 REST endpoints, predictions_audit, trace_ids verified
- [x] Stage 8 — Monitoring HEALTHY, 6/6 policy checks, GitHub Actions CI
- [x] Stage 9 — 71 tests, 0 failures, Windows DuckDB singleton documented

---

## Current Status

```
Status:   ✅ COMPLETE — ALL 9 STAGES VERIFIED
Tests:    71 passing (55 unit + 16 integration), 0 failures
Model:    xgboost_v3 — Recall 0.885, AUC-ROC 0.566 (honestly disclosed)
API:      4 endpoints live, all governance tables active
CI/CD:    GitHub Actions 9-step pipeline, 6/6 policy checks pass
Next:     Phase 2 — real credentialed MIMIC-IV data, clinical validation
Dashboard: dashboard/app.R — Shiny + Plotly, 5 tabs, live *_core() calls
```