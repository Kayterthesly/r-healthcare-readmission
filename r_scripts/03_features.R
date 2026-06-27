# ============================================================
# r_scripts/03_features.R
# r-healthcare-readmission — Stage 3
# ============================================================
# v3 CORRECTION: high_risk_dx_flag was saturating at 88% of visits
# (binary "at least one high-risk code in ~15 draws" collapses a
# real 42.9%-vs-9.4% per-code signal down to a 2.9pp readmit-rate
# gap). Added pct_high_risk_dx (fraction of THIS visit's diagnoses
# that are high-risk) alongside the flag — a continuous measure
# that cannot saturate the same way.
#
# v2 (unchanged from before): lab itemids selected by NUMERIC
# coverage, not raw event volume.
# ============================================================

library(here); library(DBI); library(arrow); library(dplyr)
library(stringr); library(tibble); library(logger); library(paws)

source(here::here("global_config.R"))
source(here::here("schemas", "canonical_omop_schemas.R"))
source(here::here("r_scripts", "governance_helpers.R"))

log_info("=== 03_features.R: STAGE 3 (v3 — continuous diagnosis severity) ===")

TOP_N_LABS <- 20

VERSION_DEMOGRAPHICS  <- "v1"
VERSION_PRIOR_ADMIT   <- "v1"
VERSION_DIAGNOSIS     <- "v2"   # was v1 — added pct_high_risk_dx
VERSION_LAB_AGGREGATE <- "v2"

con <- get_db_connection()
register_cloud_tables(con)

# ============================================================
# STEP 1 — Top N lab itemids by NUMERIC coverage
# ============================================================
top_labs <- dbGetQuery(con, sprintf("
  SELECT lab_itemid,
         COUNT(*)             AS n_total,
         COUNT(numeric_value) AS n_numeric
  FROM canonical_measurement
  GROUP BY lab_itemid
  ORDER BY n_numeric DESC
  LIMIT %d
", TOP_N_LABS))
log_info("Top {TOP_N_LABS} lab itemids by numeric coverage — {format(sum(top_labs$n_numeric),big.mark=',')} numeric readings")

meds_base  <- readRDS(here::here("data", "meds_raw", ".meds_base_path.rds"))
codes_meta <- arrow::read_parquet(file.path(meds_base, "metadata", "codes.parquet"))

get_lab_description <- function(itemid) {
  matches <- codes_meta %>% filter(str_detect(code, paste0("^LAB//", itemid, "(//|$)")))
  if (nrow(matches) > 0 && !is.na(matches$description[1]) && nchar(matches$description[1]) > 0) {
    return(matches$description[1])
  }
  paste0("Lab item ", itemid, " (no description in codes.parquet)")
}
top_labs$description <- sapply(top_labs$lab_itemid, get_lab_description)

# ============================================================
# STEP 2 — Lab aggregate features, computed in SQL
# ============================================================
lab_case_exprs <- character(0)
for (i in seq_len(nrow(top_labs))) {
  itemid    <- top_labs$lab_itemid[i]
  safe_name <- paste0("lab_", itemid)
  lab_case_exprs <- c(lab_case_exprs, sprintf(
    "AVG(CASE WHEN lab_itemid = '%s' THEN numeric_value END) AS %s_mean,
     MIN(CASE WHEN lab_itemid = '%s' THEN numeric_value END) AS %s_min,
     MAX(CASE WHEN lab_itemid = '%s' THEN numeric_value END) AS %s_max",
    itemid, safe_name, itemid, safe_name, itemid, safe_name
  ))
}
lab_select_sql <- paste(lab_case_exprs, collapse = ",\n  ")

lab_features <- dbGetQuery(con, sprintf("
  SELECT
    hadm_id,
    COUNT(*)                  AS total_lab_count,
    COUNT(DISTINCT lab_itemid) AS distinct_lab_types,
    %s
  FROM canonical_measurement
  GROUP BY hadm_id
", lab_select_sql))
log_info("lab_features: {nrow(lab_features)} visits x {ncol(lab_features)} columns")

# ============================================================
# STEP 3 — Prior admission count (self-join, SQL)
# ============================================================
prior_adm <- dbGetQuery(con, "
  SELECT a1.hadm_id, COUNT(a2.hadm_id) AS n_prior_admissions
  FROM canonical_visit a1
  LEFT JOIN canonical_visit a2
    ON a1.subject_id = a2.subject_id AND a2.admit_time < a1.admit_time
  GROUP BY a1.hadm_id
")
log_info("prior_adm: {nrow(prior_adm)} visits")

# ============================================================
# STEP 4 (v3) — Diagnosis features: count + FLAG + CONTINUOUS pct.
#          One query, one GROUP BY — flag and percentage share the
#          same CASE WHEN logic, computed together for consistency.
# ============================================================
HIGH_RISK_SQL <- "
     icd_code LIKE 'I50%'   -- heart failure (ICD-10)
  OR icd_code LIKE '428%'   -- heart failure (ICD-9)
  OR icd_code LIKE 'J44%'   -- COPD (ICD-10)
  OR icd_code LIKE '491%' OR icd_code LIKE '492%' OR icd_code LIKE '496%'
  OR icd_code LIKE 'N18%'   -- CKD (ICD-10)
  OR icd_code LIKE '585%'   -- CKD (ICD-9)
  OR icd_code LIKE 'A41%'   -- sepsis (ICD-10)
  OR icd_code LIKE '038%'   -- sepsis (ICD-9)
  OR icd_code LIKE 'I21%'   -- acute MI (ICD-10)
  OR icd_code LIKE '410%'   -- acute MI (ICD-9)
"

dx_features <- dbGetQuery(con, sprintf("
  SELECT
    hadm_id,
    COUNT(*)                              AS n_diagnoses,
    COUNT(DISTINCT icd_code)              AS n_distinct_diagnoses,
    AVG(CASE WHEN %s THEN 1.0 ELSE 0.0 END) AS pct_high_risk_dx,
    MAX(CASE WHEN %s THEN 1 ELSE 0 END)     AS high_risk_dx_flag
  FROM canonical_condition
  GROUP BY hadm_id
", HIGH_RISK_SQL, HIGH_RISK_SQL))
log_info("dx_features: {nrow(dx_features)} visits | mean pct_high_risk_dx: {round(mean(dx_features$pct_high_risk_dx),3)} | flag rate: {round(100*mean(dx_features$high_risk_dx_flag),1)}%")

# ============================================================
# STEP 5 — Demographics + base visit table
# ============================================================
demographics <- dbGetQuery(con, "SELECT subject_id, gender, age_at_first_admit, is_deceased FROM canonical_person")
visit_base   <- dbGetQuery(con, "SELECT * FROM canonical_visit")

close_db_connection(con)

# ============================================================
# STEP 6 — Join everything into ONE flat table
# ============================================================
features_v1 <- visit_base %>%
  left_join(demographics, by = "subject_id") %>%
  left_join(prior_adm,    by = "hadm_id") %>%
  left_join(dx_features,  by = "hadm_id") %>%
  left_join(lab_features, by = "hadm_id") %>%
  mutate(
    n_prior_admissions   = coalesce(n_prior_admissions, 0L),
    n_diagnoses          = coalesce(n_diagnoses, 0L),
    n_distinct_diagnoses = coalesce(n_distinct_diagnoses, 0L),
    pct_high_risk_dx     = coalesce(pct_high_risk_dx, 0),
    high_risk_dx_flag    = coalesce(high_risk_dx_flag, 0),
    total_lab_count      = coalesce(total_lab_count, 0L),
    distinct_lab_types   = coalesce(distinct_lab_types, 0L)
  )

log_info("features_v1 assembled: {nrow(features_v1)} rows x {ncol(features_v1)} columns")

leakage_cols  <- c("next_admit_time", "days_to_next")
found_leakage <- intersect(leakage_cols, names(features_v1))
if (length(found_leakage) > 0) stop("LEAKAGE DETECTED: ", paste(found_leakage, collapse = ", "))
log_info("Leakage check passed")

# ── Quick sanity print: does pct_high_risk_dx preserve more signal
#    than the flag did? ──
sanity <- features_v1 %>%
  mutate(pct_bucket = cut(pct_high_risk_dx, breaks = c(-0.01,0.1,0.3,0.6,1.01))) %>%
  group_by(pct_bucket) %>%
  summarise(n = n(), readmit_rate = round(100*mean(readmit_30d),2), .groups="drop")
log_info("readmit_30d rate by pct_high_risk_dx bucket (want a real gradient, not flat):")
print(sanity)

# ============================================================
# STEP 7 — Write to MinIO + governance entries
# ============================================================
out_dir <- here::here("data", "temp_synth")
dir.create(out_dir, showWarnings = FALSE)
fp <- file.path(out_dir, "features_v1.parquet")
arrow::write_parquet(features_v1, fp)

s3_client <- paws::s3(config = list(
  credentials = list(creds = list(
    access_key_id     = Sys.getenv("CLOUD_ACCESS_KEY_ID"),
    secret_access_key = Sys.getenv("CLOUD_SECRET_ACCESS_KEY"))),
  endpoint = Sys.getenv("CLOUD_ENDPOINT"),
  region   = Sys.getenv("CLOUD_REGION", "us-east-1")
))
s3_client$put_object(
  Bucket = Sys.getenv("CLOUD_BUCKET_NAME"), Key = "features_v1.parquet",
  Body = readBin(fp, "raw", n = file.info(fp)$size)
)
log_info("features_v1.parquet uploaded ({round(file.info(fp)$size/1e6,2)} MB)")

gov_con <- get_db_connection()
write_feature_registry(gov_con, "demographics", VERSION_DEMOGRAPHICS, "static",
                       "r_scripts/03_features.R", "Static per-patient — no leakage risk", Sys.info()[["user"]])
write_feature_registry(gov_con, "prior_admission_count", VERSION_PRIOR_ADMIT, "all admissions before this one",
                       "r_scripts/03_features.R", "Self-join filters admit_time < THIS visit's admit_time — leakage-safe by construction", Sys.info()[["user"]])
write_feature_registry(gov_con, "diagnosis_count_and_high_risk_flag", VERSION_DIAGNOSIS, "this visit only",
                       "r_scripts/03_features.R", "v2: added pct_high_risk_dx (continuous) alongside high_risk_dx_flag (binary) — the binary flag saturates at 88% of visits and dilutes a real per-code signal down to a 2.9pp readmit gap; the continuous measure preserves it", Sys.info()[["user"]])
write_feature_registry(gov_con, sprintf("lab_aggregates_top%d", TOP_N_LABS), VERSION_LAB_AGGREGATE, "this visit only",
                       "r_scripts/03_features.R", "v2: itemids selected by NUMERIC coverage, not raw volume. NOT imputed, NA preserved for Stage 4 recipe", Sys.info()[["user"]])
close_db_connection(gov_con)

file.remove(fp)
log_info("=== STAGE 3 COMPLETE (v3) — features_v1 live in MinIO ===")