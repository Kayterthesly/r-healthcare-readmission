<!-- HEADER BADGES -->
<div align="center">

# 🏥 Healthcare Readmission Forecasting Pipeline

[![R](https://img.shields.io/badge/Built_with-R_4.5.2-276DC3?style=for-the-badge&logo=r&logoColor=white)](https://www.r-project.org/)
[![Railway](https://img.shields.io/badge/API-Railway-0B0D0E?style=for-the-badge&logo=railway&logoColor=white)](https://r-healthcare-readmission-production.up.railway.app/health)
[![shinyapps.io](https://img.shields.io/badge/Dashboard-shinyapps.io-4E9AF1?style=for-the-badge&logo=shiny&logoColor=white)](https://e9yw5n-kayterthesly.shinyapps.io/healthcare-readmission-pipeline/)
[![Backblaze B2](https://img.shields.io/badge/Storage-Backblaze_B2-E05B26?style=for-the-badge)](https://www.backblaze.com/b2/cloud-storage.html)
[![GitHub Actions](https://img.shields.io/badge/CI/CD-GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)](https://github.com/Kayterthesly/r-healthcare-readmission/actions)
[![Tests](https://img.shields.io/badge/Tests-71_Passing-27ae60?style=for-the-badge&logo=checkmarx&logoColor=white)]()
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)]()

**A production-grade, end-to-end ML pipeline that predicts 30-day hospital readmission risk, retrieves evidence-based clinical guidelines via RAG, and serves everything through a live REST API and interactive dashboard.**

[🌐 Live Dashboard](https://e9yw5n-kayterthesly.shinyapps.io/healthcare-readmission-pipeline/) • [⚡ Live API](https://r-healthcare-readmission-production.up.railway.app/health) • [📂 GitHub](https://github.com/Kayterthesly/r-healthcare-readmission)

> ⚠️ **FOR PORTFOLIO DEMONSTRATION ONLY — NOT FOR CLINICAL USE.**  
> Model trained on 100-patient synthetic data. AUC-ROC 0.566 honestly disclosed.

</div>

---

## 📋 Table of Contents

- [Business Problem](#-business-problem)
- [Live Demo](#-live-demo)
- [Architecture](#-architecture)
- [Pipeline Stages](#-pipeline-stages)
- [Model Performance](#-model-performance)
- [Key Findings](#-key-findings-honestly-disclosed)
- [Tech Stack](#-tech-stack)
- [API Reference](#-api-reference)
- [Governance Layer](#-governance-layer)
- [Testing](#-testing)
- [Run Locally](#-run-locally)
- [Deployment](#-deployment)
- [Author](#-author)

---

## 💡 Business Problem

Hospital readmission within 30 days costs **$15,000–$20,000 per unnecessary event** and is a key quality indicator monitored by CMS and insurance providers. This pipeline:

- **Flags high-risk patients** at discharge using structured EHR data
- **Explains each prediction** with the top factors that drove the risk score
- **Retrieves relevant clinical guidelines** for the patient's specific conditions via RAG
- **Generates cited discharge recommendations** for clinical review
- **Logs every decision** with a full governance audit trail (trace_id, model version, input hash)

---

## 🌐 Live Demo

| Service | URL | Details |
|---------|-----|---------|
| 📊 **Interactive Dashboard** | [shinyapps.io](https://e9yw5n-kayterthesly.shinyapps.io/healthcare-readmission-pipeline/) | 5 tabs: Overview · Patient Risk · Model Performance · Fairness · Governance |
| ⚡ **REST API** | [Railway](https://r-healthcare-readmission-production.up.railway.app/health) | 4 endpoints: /health · /predict · /explain · /rag/summary |
| 💾 **Object Storage** | Backblaze B2 | 9 Parquet files, 82 MB, S3-compatible |
| 🔧 **Source Code** | [GitHub](https://github.com/Kayterthesly/r-healthcare-readmission) | Public, full history |

### Quick API Test

```bash
# Health check
curl https://r-healthcare-readmission-production.up.railway.app/health

# Live prediction (returns risk score, tier, trace_id, top drivers)
curl -X POST "https://r-healthcare-readmission-production.up.railway.app/predict?hadm_id=800040634"
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DATA LAYER (Backblaze B2)                         │
│  syn_person · syn_visit · syn_condition · syn_measurement            │
│  canonical_* (4 tables) · features_v1                               │
└─────────────────────┬───────────────────────────────────────────────┘
                      │ DuckDB + httpfs (SQL over Parquet)
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    INFERENCE LAYER (Railway)                          │
│                                                                       │
│  GET  /health      → liveness + model version                        │
│  POST /predict     → XGBoost v3 risk score + top drivers             │
│  POST /explain     → per-feature delta vs training median            │
│  POST /rag/summary → TF-IDF retrieval + Gemini discharge rec         │
│                                                                       │
│  Every call: trace_id stamped · predictions_audit written             │
└─────────────────────┬───────────────────────────────────────────────┘
                      │ httr2 POST calls
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  PRESENTATION LAYER (shinyapps.io)                   │
│  Pipeline Overview · Patient Risk · Model Performance                 │
│  Fairness Analysis · Governance Monitor                               │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                  GOVERNANCE LAYER (DuckDB, 8 tables)                 │
│  ingest_metadata · feature_registry · model_registry                 │
│  fairness_reports · rag_chunks · rag_index_metadata                  │
│  llm_call_log · predictions_audit                                    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                  CI/CD LAYER (GitHub Actions)                         │
│  lint → renv restore → script check → metadata validation           │
│  recall gate (≥0.85) → decisions policy → unit tests               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📦 Pipeline Stages

| Stage | Name | Status | Key Output |
|-------|------|--------|------------|
| 0 | Workspace & Environment | ✅ | `renv.lock`, `global_config.R`, MinIO/B2 connection |
| 1 | Synthetic MIMIC-IV Dataset | ✅ | 15,000 patients, 4 tables, severity-linked (v2) |
| 2 | Ingest & Canonical Casting | ✅ | `canonical_*` tables, `ingest_metadata` governance |
| 3 | Feature Engineering | ✅ | `features_v1` (41,358 × 81 cols), zero leakage |
| 4 | Modeling & Evaluation | ✅ | `xgboost_v3` — Recall 0.885, AUC-ROC 0.566 |
| 5 | Explainability & Fairness | ✅ | Permutation importance, 19 fairness governance rows |
| 6 | RAG Retrieval & LLM Wrapper | ✅ | 16 chunks, 40/30/30 hybrid, Section 12 contract |
| 7 | API & Deployment | ✅ | 4 Plumber endpoints, `predictions_audit` table |
| 8 | Observability & CI/CD | ✅ | Monitoring report, 6/6 policy checks, GitHub Actions |
| 9 | Testing Matrix & Gating | ✅ | **71 tests, 0 failures** (55 unit + 16 integration) |

---

## 📊 Model Performance

All versions preserved in `model_registry`. Final reference model: **xgboost v3**.

| Version | Model | Recall | Precision | AUC-ROC | PR-AUC | Approved |
|---------|-------|--------|-----------|---------|--------|----------|
| v1 | glmnet | 0.895 | 0.208 | 0.568 | 0.233 | ✅ |
| v1 | xgboost | 0.873 | 0.207 | 0.545 | 0.224 | ✅ |
| v2 | glmnet | 0.877 | 0.216 | 0.574 | 0.234 | ✅ |
| v2 | xgboost | 0.896 | 0.208 | 0.556 | 0.235 | ✅ |
| v3 | glmnet | 0.878 | 0.216 | 0.568 | 0.236 | ✅ |
| **v3** | **xgboost** | **0.885** | **0.212** | **0.566** | **0.244** | **✅** |

> **`approved = TRUE` certifies Recall ≥ 0.85 only — not clinical utility.**  
> See `docs/00_locked_decisions.md` Section 13 for the full governance clarification.

### Permutation Importance (Top Features)

| Feature | AUC Drop | Role |
|---------|----------|------|
| `n_prior_admissions` | 0.0432 | Dominant signal |
| `pct_high_risk_dx` | 0.0111 | Real secondary signal |
| All lab features | < 0.002 each | Marginal / noise |

---

## 🔍 Key Findings (Honestly Disclosed)

This project surfaces its limitations rather than hiding them. That honesty is itself a technical and professional choice.

**1. Signal ceiling from a 100-patient source**  
The real MIMIC-IV MEDS demo contains 100 patients. AUC-ROC 0.566 reflects the genuine correlation available in that source — not a modeling failure. Documented in `docs/00_locked_decisions.md` Section 13.

**2. Severity-linked synthesis required (Stage 1 v2)**  
Initial synthesis generated clinical content and readmission timing independently, producing near-random AUC (0.55). A literature-grounded fix linked severity to both timing and diagnosis sampling — explicitly documented as engineered enrichment, not empirical discovery.

**3. Fairness flag on race dimension**  
87pp recall gap across racial subgroups detected and flagged. Most likely a noise artifact of thin representation in a 100-patient source. The pipeline correctly detected and flagged it regardless of cause.

**4. Test-set-adaptive tuning disclosed**  
Three diagnostic rounds used test-set AUC as the upstream decision signal. Disclosed explicitly; iteration stopped at round 3 for methodological integrity.

---

## 🛠️ Tech Stack

| Component | Tool | Purpose |
|-----------|------|---------|
| Language | R 4.5.2 + SQL | Core pipeline |
| Package manager | renv | Reproducible environment lock |
| Database engine | DuckDB + httpfs | SQL queries direct against Parquet in cloud storage |
| Object storage | Backblaze B2 (S3-compatible) | 82 MB of Parquet data, zero egress cost in dev |
| Data synthesis | synthpop | Statistically faithful patient synthesis |
| ML framework | tidymodels | Unified model lifecycle |
| Primary model | XGBoost | High recall, gradient boosting |
| Baseline model | glmnet | Elastic net logistic regression |
| Class balancing | ROSE | Synthetic oversampling (train only) |
| RAG retrieval | TF-IDF + 40/30/30 hybrid | Base R, no extra packages, fully auditable |
| LLM connector | ellmer | Gemini API (version-robust namespace detection) |
| REST API | plumber | 4 endpoints, `*_core()` testable pattern |
| Dashboard | Shiny + shinydashboard + Plotly | 5-tab interactive dashboard |
| Monitoring | r_scripts/08_monitoring.R | PSI drift, governance completeness |
| CI/CD | GitHub Actions | 9-step pipeline on every push |
| Policy check | R-native (6 policies) | Governance invariant enforcement |
| Testing | testthat | 71 tests (55 unit + 16 integration) |
| Audit trail | uuid + digest | trace_id + data hashes |
| Paths | here | Machine-independent, deployment-safe |
| Logging | logger | Structured runtime logs |

---

## ⚡ API Reference

Base URL: `https://r-healthcare-readmission-production.up.railway.app`

### `GET /health`
```json
{
  "status": "ok",
  "model_version": "v3",
  "index_version": "v1",
  "timestamp": "2026-07-04T07:00:26",
  "endpoints": ["/health", "/predict", "/explain", "/rag/summary"]
}
```

### `POST /predict?hadm_id={id}`
Returns risk score, tier, top feature drivers, and `trace_id`. Writes to `predictions_audit`.

```json
{
  "trace_id": "485a24ad-53db-4fbb-91f5-847f398e9359",
  "model_version": "v3",
  "predicted_risk": 0.6921,
  "risk_tier": "high",
  "threshold": 0.58,
  "flagged": true,
  "top_drivers": "n_prior_admissions = -0.48 (+0.00 below median) | ...",
  "disclaimer": "FOR PORTFOLIO DEMONSTRATION ONLY — NOT FOR CLINICAL USE."
}
```

### `POST /explain?hadm_id={id}`
Returns structured per-feature explanation with delta vs. training median.

### `POST /rag/summary?hadm_id={id}&icd_families={codes}`
Returns RAG-cited discharge recommendation. Example: `icd_families=I50,J44` (HF + COPD).

```json
{
  "trace_id": "...",
  "summary": "DISCHARGE RECOMMENDATION: Patient presents with 69.2% predicted 30-day readmission risk...",
  "citations": ["hf_discharge_protocol", "copd_readmission_prevention", "high_risk_readmission_criteria"]
}
```

---

## 🗄️ Governance Layer

All 8 tables live in local DuckDB (`data/local_query_cache.duckdb`):

| Table | Rows | Stage | Design Pattern |
|-------|------|-------|----------------|
| `ingest_metadata` | 4+ | 2 | Append-only; PHI gate |
| `feature_registry` | 4 | 3 | Idempotent by (feature_name, version) |
| `model_registry` | 6 | 4 | Append-only; all training runs preserved |
| `fairness_reports` | 19 | 5 | Append-only; one row per subgroup |
| `rag_chunks` | 16 | 6 | Overwrite on index rebuild |
| `rag_index_metadata` | 1+ | 6 | Append-only; each rebuild traceable |
| `llm_call_log` | 8+ | 6–7 | Append-only; request/response as hashes |
| `predictions_audit` | 15+ | 7 | Append-only; patient_id and input as hashes |

---

## 🧪 Testing

```
tests/
├── unit/
│   ├── setup.R                     ← DuckDB singleton + WD fix
│   ├── test_schema_validation.R    ← 7 tests
│   ├── test_api_core.R             ← 8 tests
│   ├── test_rag_retrieval.R        ← 5 tests
│   └── test_governance_helpers.R   ← 5 tests
└── integration/
    ├── setup.R
    └── test_pipeline_e2e.R         ← 5 tests
```

**Total: 71 tests | 0 failures**

```r
# Run all tests
testthat::test_dir("tests/unit")
testthat::test_dir("tests/integration")
```

> **Windows DuckDB note:** Tests use a connection singleton pattern in `setup.R` to prevent OS file-lock conflicts on rapid sequential connect/disconnect cycles.

---

## 🚀 Run Locally

### Prerequisites
- R 4.5.2 · RStudio · Docker Desktop · Git

### Setup

```bash
git clone https://github.com/Kayterthesly/r-healthcare-readmission.git
cd r-healthcare-readmission
```

```r
# Restore all packages
renv::restore(prompt = FALSE)

# Configure secrets
file.edit(".Renviron")
# Add: CLOUD_ACCESS_KEY_ID, CLOUD_SECRET_ACCESS_KEY, CLOUD_ENDPOINT, etc.
```

```bash
# Start MinIO (local object storage)
docker compose up -d
```

```r
# Run the full pipeline (Stages 1–9 in order)
source("r_scripts/01_synthetic_mimic_generator.R")
source("r_scripts/02_ingest_and_cast.R")
source("r_scripts/03_features.R")
source("r_scripts/04_train_models.R")
source("r_scripts/05_explainability_fairness.R")
source("rag/rag_indexing.R")

# Start the API (separate R session)
source("api/run_api.R")

# Launch local dashboard
shiny::runApp("dashboard/app.R", launch.browser = TRUE)
```

### Storage Provider Swap
Moving from local MinIO to Backblaze B2 (or AWS S3, Cloudflare R2) requires editing **6 lines** in `.Renviron` and **zero lines** of pipeline code.

---

## ☁️ Deployment

| Layer | Platform | Config |
|-------|----------|--------|
| Object storage | Backblaze B2 | S3-compatible, 9 Parquet files |
| REST API | Railway (Docker) | `Dockerfile` + `railway.toml` |
| Dashboard | shinyapps.io | Pre-computed bundle + live API calls |

### Deploy API to Railway
```bash
# Railway auto-deploys on push to main
git push origin main
```

### Deploy Dashboard to shinyapps.io
```r
rsconnect::deployApp(
  appDir  = "dashboard",
  appName = "healthcare-readmission-pipeline",
  account = "your-shinyapps-account"
)
```

---

## 📁 Repository Structure

```
r-healthcare-readmission/
├── global_config.R                    ← Provider-agnostic DuckDB + B2 config
├── renv.lock                          ← Full package lock (reproducible)
├── Dockerfile                         ← Railway deployment
├── railway.toml                       ← Railway config
├── .github/workflows/ci.yml          ← 9-step GitHub Actions CI
│
├── r_scripts/
│   ├── 01_synthetic_mimic_generator.R ← 5-section synthesis (v2, severity-linked)
│   ├── 02_ingest_and_cast.R
│   ├── 03_features.R                  ← DuckDB SQL on 9M-row lab data
│   ├── 04_train_models.R              ← XGBoost + glmnet (3 diagnostic rounds)
│   ├── 05_explainability_fairness.R   ← Permutation importance + fairness
│   ├── 08_monitoring.R                ← Health report across all governance tables
│   └── governance_helpers.R           ← 7 write functions (Section 12)
│
├── schemas/canonical_omop_schemas.R   ← 4 schemas + validation
├── rag/
│   ├── guidelines/                    ← 8 synthetic clinical guideline docs
│   ├── rag_indexing.R                 ← TF-IDF index builder
│   ├── llm_wrapper.R                  ← generate_discharge_summary()
│   └── tfidf_index_v1.rds             ← 16 chunks × 241 terms
│
├── api/
│   ├── plumber.R                      ← 4 REST endpoints (*_core() pattern)
│   └── run_api.R
│
├── dashboard/
│   ├── app.R                          ← shinyapps.io deployment version
│   └── data/deploy_bundle.rds         ← Pre-computed governance snapshot
│
├── infra/policies/model_policy_check.R ← 6 governance policies
├── models/artifacts/                   ← All .rds + metadata JSON (v1/v2/v3)
├── tests/                              ← 71 tests (testthat)
├── docs/
│   ├── README.md
│   └── 00_locked_decisions.md         ← 13 sections of governance decisions
└── notes/                             ← Stage-by-stage handwritten notes (Stage 0–9)
```

---

## 👤 Author

**Kingsley Akenu** — Data Analyst → Data Scientist  
📍 Lagos, Nigeria | 🐦 [@Kayterthesly](https://twitter.com/Kayterthesly) | KAIZEN 改善

> *"A model that says AUC 0.566 with full documentation of why and what would fix it is more credible than one that says AUC 0.85 with unexplained methodology."*

---

<div align="center">

**Built with KAIZEN (改善) — continuous, honest improvement**

[![GitHub](https://img.shields.io/badge/View_on-GitHub-181717?style=for-the-badge&logo=github)](https://github.com/Kayterthesly/r-healthcare-readmission)
[![Live Demo](https://img.shields.io/badge/Live-Dashboard-4E9AF1?style=for-the-badge&logo=shiny)](https://e9yw5n-kayterthesly.shinyapps.io/healthcare-readmission-pipeline/)
[![API](https://img.shields.io/badge/Live-API-0B0D0E?style=for-the-badge&logo=railway)](https://r-healthcare-readmission-production.up.railway.app/health)

</div>
