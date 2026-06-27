# Stage 0 — Locked Project Decisions

**Project:** r-healthcare-readmission
**Author:** Kingsley Akenu
**Date:** 2026-06-19
**Status:** LOCKED

---

## 1. Mission

Build a production-grade, auditable, scalable, R-first hybrid healthcare
intelligence system that predicts 30-day readmission risk from structured
data, and uses RAG to retrieve clinical guidance and generate personalized,
cited discharge recommendations. Outputs must be auditable, cited,
reproducible, versioned, traceable via APIs, and safe to swap from
synthetic to production data with minimal code changes.

---

## 2. Target Variable (Y1)
readmit_30d — binary classification

1 = readmitted within 30 days of discharge

0 = not readmitted within 30 days

---

## 3. Target Output (Y2) — RAG Clinical Summary Schema

Risk explanation
Discharge mitigation recommendations
Follow-up appointment timeline
Medication cautions / contraindications
Lifestyle / dietary recommendations
Retrieved guideline citation (MANDATORY — no recommendation

without a cited source)


---

## 4. Model Optimization Priority
Primary:    Recall ≥ 0.85

Secondary:  Acceptable AUC-ROC

Gating:     Block model promotion if recall < 0.85 on holdout

---

## 5. Retrieval Strategy — Hybrid
40% Diagnosis similarity   (ICD-10 / OMOP concept)

30% Lab-value proximity    (creatinine, HbA1c, BUN, etc.)

30% Embedding similarity   (clinical note text)

---

## 6. Data Strategy
Phase 1: MIMIC-IV MEDS demo (100 real patients, public, no

credentialing) → synthpop synthesis → 15,000 patients

Phase 2: Real MIMIC-IV / production EHR source

Migration rule: swap data source via ENV_MODE only — zero

pipeline code changes

---

## 7. Model Strategy
Phase 1: Cloud LLM API (Gemini, via ellmer) — fast iteration

Phase 2: Cloud validation

Phase 3: Local open-source inference (Ollama + Llama 3) — privacy

Rule: LLM behind ONE wrapper function — swap models, change one line

---

## 8. Architecture Rule
Modular. Never tightly coupled.

Single data access layer: global_config.R → get_db_connection()

Strict schema casting before any downstream use (Stage 2)

Batch chunking for all large data operations

OMOP concept IDs preferred over free-text source values

---

## 9. Storage Decision (Stage 0 addition, 2026-06-19)
Planned:  Cloudflare R2 (S3-compatible, free tier, no egress fees)

Blocked:  R2 signup hit a known, recurring Cloudflare billing bug

("Add R2 subscription" stuck in a loop) — confirmed via

search as a real, repeatedly-reported issue, not unique

to this attempt
Decided:  MinIO (local Docker) as interim S3-compatible storage

Why this works without architectural compromise:

global_config.R reads provider, endpoint, credentials, and SSL

mode entirely from .Renviron. Moving to R2 (or Backblaze B2, or

AWS S3) later requires editing 6 lines in .Renviron and zero

lines of pipeline code.

---

## 10. Complete Decision Register

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Target variable | readmit_30d (binary) | CMS/MIMIC-IV standard |
| Primary metric | Recall ≥ 0.85 | Missing risk > false alarm |
| Retrieval | Hybrid 40/30/30 | Clinical + biochemical + contextual |
| Data Phase 1 | MEDS demo → synthpop → 15k | Real patterns, no credentialing |
| Storage (interim) | MinIO local Docker | Zero signup friction, swappable |
| Storage (planned) | Cloudflare R2 | Free, zero egress, S3-compatible |
| Database engine | DuckDB + httpfs | Queries Parquet directly, no full download |
| LLM Phase 1 | Gemini via ellmer | Free tier, fast |
| LLM Phase 2 | Ollama/Llama 3 | Privacy, local inference |
| Package management | renv | Reproducible, locked versions |
| Architecture | Modular, wrapper-abstracted | Swappable components |

---

## 11. What This System Is NOT
This is NOT autonomous medical decision-making.

All outputs are for CLINICIAN REVIEW only.

The system supports clinical decisions — it does not make them.

---

## 12. Governance & Compliance Layer (added 2026-06-19)
Decision: adopt a non-intrusive governance layer alongside the existing

R pipeline — policy-as-code gates, audit logging, model registry

metadata, ingest classification, and retraining triggers. Additive

only; does not change any decision in Sections 1–11.

### Component → Stage Map (where each piece gets BUILT, not designed)

| Governance Component | Lives In | Built At Stage | What It Adds |
|---|---|---|---|
| Ingest & Classification | `r_scripts/02_ingest_and_cast.R` | Stage 2 | `ingest_metadata` table: job_id, source, rows, data_hash, sensitivity_label, operator, timestamps. Rejects ingest if `sensitivity_label == "PHI"` and `ENV_MODE != "production"` |
| Feature Registry & Validator | `r_scripts/03_features.R` + `tests/data_tests.R` | Stage 3 | `feature_registry` table: feature_name, version, window, computation source, created_by/at. CI test asserts no future leakage, correct time windows |
| Model Registry & Metadata | `r_scripts/04_train_models.R` + `models/` | Stage 4 | `models/metadata_<version>.json`: model_version, training_hash, metrics, fairness_report_path, `clinical_signoff` (user, timestamp), `approved` (bool). Promotion requires CI gates + sign-off |
| RAG Index & LLM Wrapper Contract | `rag/rag_indexing.R`, `rag/llm_wrapper.R` | Stage 6 | Index metadata: index_version, source_hash, chunking_strategy, embedding_model. Every LLM call logged with request/response hash. Structured contract: `{summary_text, citations, retrieval_debug, trace_id, model_version, index_version}` |
| Audit & Traceability | `api/plumber.R` | Stage 7 | Immutable `predictions_audit` table: trace_id, patient_id_hash, input_hash, model_version, risk_tier, explanation_snippet, user_id, timestamp, env. Every API response carries trace_id + model_version |
| Policy Engine (OPA) + Admission Controls | `infra/policies/*.rego`, `infra/k8s/` | Stage 8 | Rego policies validate model metadata + deployment manifests via `conftest`/`opa eval`. Kubernetes Gatekeeper enforces container egress, allowed base images, required env vars |
| CI/CD Governance Pipeline | `.github/workflows/ci.yml` | Stage 8 | Pipeline order: lint → `renv::restore()` → unit tests → data tests → model smoke-train → metrics check → OPA policy checks → build image → push → canary deploy |
| Monitoring & Retraining | `infra/` + Stage 8/9 monitoring | Stage 8–9 | Exports recall, precision, drift score, retrieval recall@k, latency. Alerts on recall below threshold or drift above threshold trigger a retrain job, which must pass the same gates |

### Rollout Order (3 sprints, mapped onto our existing stages)
Sprint 1 (Stages 2-3): ingest_metadata + feature_registry + data tests in CI

Sprint 2 (Stage 4):    model metadata + OPA/conftest policy checks, block

promotion on policy failure

Sprint 3 (Stages 6-9): predictions_audit, RAG contract, plumber instrumentation,

metrics export, retrain orchestration

### Why deferred rather than built now

Every component above instruments a script that doesn't exist yet (Stage
2's ingest script, Stage 4's training script, Stage 7's API). Writing
governance code with nothing real to govern produces untestable
placeholders. Each piece gets built at its mapped stage, against real
code, with real data flowing through it — consistent with the project's
existing rule of locking the decision in writing first, then implementing
it when its dependencies actually exist.

---

## 13. Model Gating Clarification (added 2026-06-21, after Stage 4)

`approved` in `model_registry` reflects ONLY whether a model meets the
mandated Recall ≥ 0.85 floor (Section 4) at its chosen operating
threshold. It is NOT a holistic endorsement of clinical utility,
discriminative power, or deployment-readiness. A near-random classifier
can satisfy `approved = TRUE` by lowering its threshold far enough —
this is an intentional, known property of a recall-floor gate, not a
bug, but it must never be read as "this model is good," only "this
model meets the minimum safety floor on catching positives, at the
precision cost the threshold sweep reports honestly alongside it."

**Stage 4 outcome:** best result achieved was `xgboost v3` — AUC-ROC
0.566, PR-AUC 0.244 — a real, modest improvement over the v1 baseline
(0.545) but still well below conventional thresholds for genuine
clinical discriminative utility. Root cause, confirmed across three
rounds of diagnosis: this 100-patient-demo-derived synthetic dataset
has limited true correlation between clinical severity (diagnoses,
labs) and readmission timing, because Stage 1's visit-timing and
diagnosis/lab-content generation were originally built as independent
processes. A documented, literature-grounded enrichment (severity-
linked timing + diagnosis sampling) added real but modest signal
(readmit rate by severity: 17.7% vs. 22.8%).

**Decision:** carry `xgboost_v3` forward as the reference model for
Stage 5+, explicitly flagged as an architecture-validation model, not
a deployment-ready one. Further iteration on Stage 1 synthesis or
Stage 4 hyperparameters is deliberately NOT pursued further now, for
two reasons: (1) diminishing returns — three iterations confirmed a
stable signal ceiling given a fixed, immutable 100-patient real
source; (2) methodological integrity — repeated iteration using TEST
SET performance as the feedback signal for upstream architecture
changes is a form of test-set-adaptive tuning, and continuing further
risks the test set's reported performance becoming optimistic relative
to genuinely held-out data.

**Forward-looking note:** if real, credentialed MIMIC-IV data replaces
the demo source in a future Phase 2 (Section 6), this signal-ceiling
concern is expected to resolve — real clinical correlations between
severity and readmission timing are well-established in the
literature. This is a property of working from a small public demo,
not of the modeling approach.

**Locked by:** Kingsley Akenu — 2026-06-19