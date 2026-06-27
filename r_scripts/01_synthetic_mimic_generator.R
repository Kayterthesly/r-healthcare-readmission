# ============================================================
# r_scripts/01_synthetic_mimic_generator.R
# r-healthcare-readmission — Unified Workflow
# ============================================================
# SECTION 1: Load real MIMIC-IV MEDS demo (100 patients) and
#            reshape the long event log into core wide tables.
# SECTION 2: synthpop synthesis to 15,000 patients.
# SECTION 3: condition (diagnosis) synthesis.
# SECTION 4: measurement (labs) synthesis, vectorized + capped.
# SECTION 5: write to Parquet, upload to MinIO, cleanup.
#
# v2 (2026-06-21): Stage 4's first training run found near-random
# AUC (0.55-0.57) with signal concentrated almost entirely in
# n_prior_admissions. Root cause: v1 generated visit timing and
# diagnosis/lab content as INDEPENDENT processes, so nothing in
# the synthetic data correlated clinical severity with readmission
# timing. v2 introduces a shared latent "is_severe" draw per visit
# that links timing (Section 2) and diagnosis sampling (Section 3).
# is_severe is used internally only -- explicitly EXCLUDED from
# the final uploaded tables to avoid becoming a leakage shortcut
# (same principle as is_deceased's exclusion in Stage 4).
# ============================================================

library(here); library(arrow); library(dplyr)
library(stringr); library(tidyr); library(logger)

SYNTH_VERSION <- "v2"
log_info("=== 01_synthetic_mimic_generator.R: SECTION 1 ({SYNTH_VERSION}) ===")

# ── Locate the real MEDS data ──────────────────────────────
meds_files <- list.files(here::here("data", "meds_raw"), recursive = TRUE,
                         full.names = TRUE, pattern = "\\.(parquet|json|txt)$")

find_meds_base <- function(any_file_path) {
  d <- dirname(any_file_path)
  for (i in 1:6) {
    if (dir.exists(file.path(d, "data")) && dir.exists(file.path(d, "metadata"))) return(d)
    parent <- dirname(d)
    if (parent == d) break
    d <- parent
  }
  stop("Could not locate MEDS_BASE.")
}
MEDS_BASE <- find_meds_base(meds_files[1])
log_info("MEDS_BASE: {MEDS_BASE}")

# ── Load and combine all three splits ──────────────────────
all_events <- bind_rows(
  read_parquet(file.path(MEDS_BASE, "data", "train",    "0.parquet")),
  read_parquet(file.path(MEDS_BASE, "data", "tuning",   "0.parquet")),
  read_parquet(file.path(MEDS_BASE, "data", "held_out", "0.parquet"))
)
log_info("Loaded {nrow(all_events)} events for {n_distinct(all_events$subject_id)} subjects")

all_events <- all_events %>%
  mutate(vocab = ifelse(str_detect(code, "//"), str_extract(code, "^[^/]+"), code))

# ============================================================
# TABLE 1: person
# ============================================================
person_gender <- all_events %>% filter(vocab == "GENDER") %>%
  distinct(subject_id, .keep_all = TRUE) %>%
  transmute(subject_id, gender = str_extract(code, "(?<=//).+"))
person_birth <- all_events %>% filter(vocab == "MEDS_BIRTH") %>%
  distinct(subject_id, .keep_all = TRUE) %>% transmute(subject_id, birth_date = as.Date(time))
person_death <- all_events %>% filter(vocab == "MEDS_DEATH") %>%
  distinct(subject_id, .keep_all = TRUE) %>% transmute(subject_id, death_date = as.Date(time))

person_real <- person_gender %>%
  left_join(person_birth, by = "subject_id") %>%
  left_join(person_death, by = "subject_id")
log_info("person_real: {nrow(person_real)} rows")

# ============================================================
# TABLE 2: visit
# ============================================================
adm_events <- all_events %>%
  filter(vocab == "HOSPITAL_ADMISSION", !is.na(hadm_id)) %>%
  distinct(hadm_id, .keep_all = TRUE) %>%
  separate(code, into = c(NA, "admission_type", "admission_location"),
           sep = "//", extra = "merge", fill = "right") %>%
  transmute(subject_id, hadm_id, admit_time = time,
            admission_type, admission_location,
            insurance, language, marital_status, race)

disch_events <- all_events %>%
  filter(vocab == "HOSPITAL_DISCHARGE", !is.na(hadm_id)) %>%
  distinct(hadm_id, .keep_all = TRUE) %>%
  transmute(hadm_id, discharge_time = time)

death_check <- all_events %>% filter(vocab == "MEDS_DEATH") %>%
  transmute(subject_id, death_time = time)

visit_real <- adm_events %>%
  inner_join(disch_events, by = "hadm_id") %>%
  mutate(los_days = as.numeric(difftime(discharge_time, admit_time, units = "days"))) %>%
  left_join(death_check, by = "subject_id") %>%
  mutate(died_this_stay = !is.na(death_time) &
           death_time >= admit_time & death_time <= discharge_time) %>%
  select(-death_time) %>%
  arrange(subject_id, admit_time) %>%
  group_by(subject_id) %>%
  mutate(
    next_admit_time = lead(admit_time),
    days_to_next     = as.numeric(difftime(next_admit_time, discharge_time, units = "days")),
    readmit_30d      = as.integer(!is.na(days_to_next) & days_to_next >= 0 & days_to_next <= 30)
  ) %>%
  ungroup() %>%
  filter(!died_this_stay)

log_info("visit_real: {nrow(visit_real)} rows (post death-exclusion)")
log_info("readmit_30d rate: {round(100*mean(visit_real$readmit_30d, na.rm=TRUE), 1)}%")

# ============================================================
# TABLE 3: condition
# ============================================================
condition_real <- all_events %>%
  filter(vocab == "DIAGNOSIS", !is.na(hadm_id)) %>%
  separate(code, into = c(NA, NA, "icd_version", "icd_code"),
           sep = "//", extra = "merge", fill = "right") %>%
  transmute(subject_id, hadm_id, icd_version, icd_code, dx_time = time)
log_info("condition_real: {nrow(condition_real)} rows")

# ── v2: real severity rate, computed empirically from real data ──
HIGH_RISK_PATTERN <- "^(I50|428|J44|491|492|496|N18|585|A41|038|I21|410)"
real_high_risk_hadm <- condition_real %>%
  filter(str_detect(icd_code, HIGH_RISK_PATTERN)) %>%
  distinct(hadm_id) %>% pull(hadm_id)

visit_real <- visit_real %>%
  mutate(is_severe_real = hadm_id %in% real_high_risk_hadm)

real_severity_rate <- mean(visit_real$is_severe_real)
log_info("v2: real severity rate (high-risk dx present): {round(100*real_severity_rate,1)}% of {nrow(visit_real)} visits")

# ============================================================
# TABLE 4: measurement
# ============================================================
measurement_real <- all_events %>%
  filter(vocab == "LAB") %>%
  separate(code, into = c(NA, "lab_itemid", "lab_unit"),
           sep = "//", extra = "merge", fill = "right") %>%
  transmute(subject_id, hadm_id, lab_itemid, lab_unit,
            lab_time = time, numeric_value, text_value)
log_info("measurement_real: {nrow(measurement_real)} rows")

dir.create(here::here("data", "temp_synth"), showWarnings = FALSE)
saveRDS(list(person = person_real, visit = visit_real,
             condition = condition_real, measurement = measurement_real,
             real_severity_rate = real_severity_rate),
        here::here("data", "temp_synth", "real_reshaped_tables.rds"))

log_info("=== SECTION 1 COMPLETE — real tables saved ===")

# ============================================================
# SECTION 2 (v2): synthpop synthesis — person + visit
#                 Timing now linked to a shared latent severity draw.
# ============================================================
library(synthpop)

set.seed(42)
N_SYNTH_PERSONS <- 15000

# ── Documented synthetic enrichment parameters ──
# NUDGE_FACTOR_SEVERE: applied ON TOP OF empirical severity-stratified
# gap resampling (which IS grounded in real data). This multiplier
# itself is NOT estimated from this 100-patient sample -- the
# stratified pools are too thin to trust a precise empirical number.
# It is a modest, explicitly-labeled assumption grounded in published
# 30-day readmission literature for heart failure, COPD, CKD, and
# sepsis, which consistently shows shorter readmission intervals
# following higher-severity index admissions. Treat as an engineered
# assumption, not a discovered pattern -- documented here and in the
# README, adjustable, and easy to set back to 1.0 (no nudge) to test
# sensitivity.
NUDGE_FACTOR_SEVERE     <- 0.85
HIGH_RISK_DX_MIX_SEVERE <- 0.40
HIGH_RISK_DX_MIX_NORMAL <- 0.05
MIN_STRATUM_SIZE        <- 15

log_info("=== SECTION 2 ({SYNTH_VERSION}): synthpop synthesis (person + visit) ===")
log_info("Enrichment params: NUDGE_FACTOR_SEVERE={NUDGE_FACTOR_SEVERE}, HIGH_RISK_DX_MIX_SEVERE={HIGH_RISK_DX_MIX_SEVERE}, HIGH_RISK_DX_MIX_NORMAL={HIGH_RISK_DX_MIX_NORMAL}")

real_tables        <- readRDS(here::here("data", "temp_synth", "real_reshaped_tables.rds"))
person_real        <- real_tables$person
visit_real         <- real_tables$visit
condition_real     <- real_tables$condition
measurement_real   <- real_tables$measurement
real_severity_rate <- real_tables$real_severity_rate

first_admit <- visit_real %>%
  group_by(subject_id) %>%
  summarise(first_admit_time = min(admit_time), .groups = "drop")

person_with_age <- person_real %>%
  inner_join(first_admit, by = "subject_id") %>%
  mutate(
    age_at_first_admit = as.numeric(difftime(first_admit_time, birth_date, units = "days")) / 365.25,
    is_deceased = factor(ifelse(!is.na(death_date), "yes", "no"), levels = c("no","yes")),
    gender = factor(gender)
  ) %>%
  filter(!is.na(age_at_first_admit), age_at_first_admit > 0, age_at_first_admit < 110)

log_info("Patients with valid demographics + admission link: {nrow(person_with_age)}")

# ── STEP C.1 — Synthesize person attributes (unchanged from v1) ──
person_synth_input <- person_with_age %>% select(gender, age_at_first_admit, is_deceased)
syn_person_model <- syn(person_synth_input, k = N_SYNTH_PERSONS, seed = 42)
new_person <- syn_person_model$syn %>%
  mutate(subject_id = 900000 + row_number()) %>%
  select(subject_id, gender, age_at_first_admit, is_deceased)
log_info("Synthetic person table: {nrow(new_person)} rows")

# ── STEP C.2 — Visits-per-patient bootstrap (unchanged from v1) ──
real_visit_counts <- as.numeric(table(visit_real$subject_id))
log_info("Real visits/patient — min:{min(real_visit_counts)} mean:{round(mean(real_visit_counts),2)} max:{max(real_visit_counts)}")
n_visits_per_synth <- sample(real_visit_counts, N_SYNTH_PERSONS, replace = TRUE)
total_synth_visits <- sum(n_visits_per_synth)
log_info("Target synthetic visit count: {total_synth_visits}")

# ── STEP C.3 — Synthesize static visit attributes (unchanged from v1) ──
visit_attr_input <- visit_real %>%
  mutate(
    admission_type = factor(ifelse(is.na(admission_type), "Unknown", admission_type)),
    insurance      = factor(ifelse(is.na(insurance),      "Unknown", insurance)),
    language       = factor(ifelse(is.na(language),       "Unknown", language)),
    marital_status = factor(ifelse(is.na(marital_status), "Unknown", marital_status)),
    race           = factor(ifelse(is.na(race),           "Unknown", race)),
    los_days       = ifelse(is.na(los_days) | los_days <= 0, 0.1, los_days)
  ) %>%
  select(admission_type, insurance, language, marital_status, race, los_days)

syn_visit_attr_model <- syn(visit_attr_input, k = total_synth_visits, seed = 42)
visit_attr_pool <- syn_visit_attr_model$syn
log_info("Synthetic visit attribute pool: {nrow(visit_attr_pool)} rows")

# ── STEP C.4 (v2) — Sequential timing, SEVERITY-LINKED ──
real_gap_pool_severe   <- visit_real %>% filter(!is.na(days_to_next), is_severe_real)  %>% pull(days_to_next)
real_gap_pool_normal   <- visit_real %>% filter(!is.na(days_to_next), !is_severe_real) %>% pull(days_to_next)
real_gap_pool_fallback <- visit_real %>% filter(!is.na(days_to_next)) %>% pull(days_to_next)
real_first_admit_range <- range(first_admit$first_admit_time)

log_info("Real gap pool — severe stratum: {length(real_gap_pool_severe)}, normal stratum: {length(real_gap_pool_normal)}, pooled fallback: {length(real_gap_pool_fallback)}")
if (length(real_gap_pool_severe) < MIN_STRATUM_SIZE || length(real_gap_pool_normal) < MIN_STRATUM_SIZE) {
  log_warn("A severity stratum is below MIN_STRATUM_SIZE={MIN_STRATUM_SIZE} — falling back to pooled gaps for that stratum at sample time")
}

build_patient_visits <- function(subj_id, n_visits, attr_rows) {
  admit_time <- as.POSIXct(
    runif(1, as.numeric(real_first_admit_range[1]), as.numeric(real_first_admit_range[2])),
    origin = "1970-01-01"
  )
  is_severe_vec <- rbinom(n_visits, 1, real_severity_rate) == 1
  
  rows <- vector("list", n_visits)
  for (i in seq_len(n_visits)) {
    los <- max(0.05, attr_rows$los_days[i])
    discharge_time <- admit_time + los * 86400
    rows[[i]] <- tibble(
      subject_id = subj_id, visit_seq = i,
      admit_time = admit_time, discharge_time = discharge_time, los_days = los,
      admission_type = attr_rows$admission_type[i], insurance = attr_rows$insurance[i],
      language = attr_rows$language[i], marital_status = attr_rows$marital_status[i],
      race = attr_rows$race[i],
      is_severe = is_severe_vec[i]
    )
    if (i < n_visits) {
      severe_now <- is_severe_vec[i]
      pool <- if (severe_now) {
        if (length(real_gap_pool_severe) >= MIN_STRATUM_SIZE) real_gap_pool_severe else real_gap_pool_fallback
      } else {
        if (length(real_gap_pool_normal) >= MIN_STRATUM_SIZE) real_gap_pool_normal else real_gap_pool_fallback
      }
      gap <- sample(pool, 1)
      if (severe_now) gap <- gap * NUDGE_FACTOR_SEVERE
      admit_time <- discharge_time + gap * 86400
    }
  }
  bind_rows(rows)
}

visit_attr_pool$.row <- seq_len(nrow(visit_attr_pool))
attr_cursor <- 1L
patient_visit_list <- vector("list", N_SYNTH_PERSONS)

for (p in seq_len(N_SYNTH_PERSONS)) {
  n_v <- n_visits_per_synth[p]
  attr_slice <- visit_attr_pool[attr_cursor:(attr_cursor + n_v - 1), ]
  attr_cursor <- attr_cursor + n_v
  patient_visit_list[[p]] <- build_patient_visits(new_person$subject_id[p], n_v, attr_slice)
}

visit_synth_raw <- bind_rows(patient_visit_list)
log_info("Built {nrow(visit_synth_raw)} synthetic visits with severity-linked sequential timing")

# ── STEP C.5 — Recompute readmit_30d, keep is_severe for Section 3 ──
visit_synth <- visit_synth_raw %>%
  mutate(hadm_id = 800000000 + row_number()) %>%
  arrange(subject_id, admit_time) %>%
  group_by(subject_id) %>%
  mutate(
    next_admit_time = lead(admit_time),
    days_to_next     = as.numeric(difftime(next_admit_time, discharge_time, units = "days")),
    readmit_30d      = as.integer(!is.na(days_to_next) & days_to_next >= 0 & days_to_next <= 30)
  ) %>%
  ungroup() %>%
  select(subject_id, hadm_id, admit_time, discharge_time, los_days,
         admission_type, insurance, language, marital_status, race,
         is_severe, readmit_30d)

synth_readmit_rate <- round(100 * mean(visit_synth$readmit_30d), 2)
log_info("Synthetic readmit_30d rate: {synth_readmit_rate}% (real was {round(100*mean(visit_real$readmit_30d,na.rm=TRUE),2)}%)")
log_info("Synthetic severity rate: {round(100*mean(visit_synth$is_severe),1)}% (real was {round(100*real_severity_rate,1)}%)")

readmit_by_severity <- visit_synth %>% group_by(is_severe) %>%
  summarise(n = n(), readmit_rate = round(100*mean(readmit_30d),2), .groups = "drop")
log_info("readmit_30d rate BY severity (this is the new signal):")
print(readmit_by_severity)

saveRDS(list(person = new_person, visit = visit_synth),
        here::here("data", "temp_synth", "synth_person_visit.rds"))

log_info("=== SECTION 2 COMPLETE — severity-linked person + visit saved ===")

# ============================================================
# SECTION 3 (v2): condition — severity-mixed diagnosis sampling
# ============================================================
log_info("=== SECTION 3 ({SYNTH_VERSION}): condition synthesis, severity-mixed ===")

synth_pv    <- readRDS(here::here("data", "temp_synth", "synth_person_visit.rds"))
new_person  <- synth_pv$person
visit_synth <- synth_pv$visit

real_dx_counts <- as.numeric(table(condition_real$hadm_id))
log_info("Real dx/visit — min:{min(real_dx_counts)} median:{median(real_dx_counts)} max:{max(real_dx_counts)}")

set.seed(43)
n_dx_per_visit <- sample(real_dx_counts, nrow(visit_synth), replace = TRUE)

code_pool_all       <- condition_real %>% transmute(icd_version, icd_code)
code_pool_high_risk <- code_pool_all %>% filter(str_detect(icd_code, HIGH_RISK_PATTERN))
log_info("Code pools — all: {nrow(code_pool_all)} rows, high-risk subset: {nrow(code_pool_high_risk)} rows")

condition_synth_list <- vector("list", nrow(visit_synth))
for (i in seq_len(nrow(visit_synth))) {
  n_dx <- n_dx_per_visit[i]
  mix  <- if (isTRUE(visit_synth$is_severe[i])) HIGH_RISK_DX_MIX_SEVERE else HIGH_RISK_DX_MIX_NORMAL
  n_high_risk <- round(n_dx * mix)
  n_general   <- n_dx - n_high_risk
  
  picks_hr  <- if (n_high_risk > 0) code_pool_high_risk[sample.int(nrow(code_pool_high_risk), n_high_risk, replace = TRUE), ] else code_pool_high_risk[0, ]
  picks_gen <- if (n_general   > 0) code_pool_all[sample.int(nrow(code_pool_all), n_general, replace = TRUE), ]             else code_pool_all[0, ]
  picks <- bind_rows(picks_hr, picks_gen)
  
  condition_synth_list[[i]] <- tibble(
    subject_id  = visit_synth$subject_id[i],
    hadm_id     = visit_synth$hadm_id[i],
    icd_version = picks$icd_version,
    icd_code    = picks$icd_code,
    dx_time     = visit_synth$discharge_time[i]
  )
  if (i %% 10000 == 0) log_info("  condition synthesis: {i}/{nrow(visit_synth)} visits")
}
condition_synth <- bind_rows(condition_synth_list)
log_info("condition_synth: {nrow(condition_synth)} rows")

high_risk_check <- condition_synth %>%
  mutate(is_hr_code = str_detect(icd_code, HIGH_RISK_PATTERN)) %>%
  left_join(visit_synth %>% select(hadm_id, is_severe), by = "hadm_id") %>%
  group_by(is_severe) %>%
  summarise(pct_high_risk_codes = round(100*mean(is_hr_code), 1), .groups = "drop")
log_info("% high-risk diagnosis codes BY severity flag (should be much higher when TRUE):")
print(high_risk_check)

saveRDS(condition_synth, here::here("data", "temp_synth", "synth_condition.rds"))
log_info("=== SECTION 3 COMPLETE ===")

# ============================================================
# SECTION 4: measurement (labs) — UNCHANGED from v1, vectorized,
#            volume-controlled. No severity-linkage in this pass —
#            scoped out to keep this fix contained; a reasonable
#            future enhancement, not required to test the current
#            hypothesis.
# ============================================================
log_info("=== SECTION 4: measurement (labs) synthesis ===")

set.seed(44)
HARD_CAP_LABS_PER_VISIT <- 300

measurement_linked   <- measurement_real %>% filter(!is.na(hadm_id))
measurement_unlinked <- measurement_real %>% filter(is.na(hadm_id))

log_info("Linked labs (has hadm_id): {format(nrow(measurement_linked),big.mark=',')} ({round(100*nrow(measurement_linked)/nrow(measurement_real),1)}%)")
log_info("Unlinked labs (no hadm_id): {format(nrow(measurement_unlinked),big.mark=',')} — out of scope, not synthesized")

real_lab_counts_per_visit <- as.numeric(table(measurement_linked$hadm_id))
log_info("Real LINKED labs/visit — min:{min(real_lab_counts_per_visit)} median:{median(real_lab_counts_per_visit)} mean:{round(mean(real_lab_counts_per_visit),1)} max:{max(real_lab_counts_per_visit)}")

n_labs_per_synth_visit <- pmin(
  sample(real_lab_counts_per_visit, nrow(visit_synth), replace = TRUE),
  HARD_CAP_LABS_PER_VISIT
)
projected_total <- sum(n_labs_per_synth_visit)
log_info("Projected synthetic measurement rows: {format(projected_total, big.mark=',')} (cap={HARD_CAP_LABS_PER_VISIT}/visit)")

lab_pool <- measurement_linked %>% transmute(lab_itemid, lab_unit, numeric_value, text_value)

expanded_subject_id <- rep(visit_synth$subject_id,    n_labs_per_synth_visit)
expanded_hadm_id    <- rep(visit_synth$hadm_id,        n_labs_per_synth_visit)
expanded_disch_time <- rep(visit_synth$discharge_time, n_labs_per_synth_visit)

pool_picks <- lab_pool[sample.int(nrow(lab_pool), projected_total, replace = TRUE), ]

measurement_synth <- tibble(
  subject_id    = expanded_subject_id,
  hadm_id       = expanded_hadm_id,
  lab_itemid    = pool_picks$lab_itemid,
  lab_unit      = pool_picks$lab_unit,
  lab_time      = expanded_disch_time,
  numeric_value = pool_picks$numeric_value,
  text_value    = pool_picks$text_value
)
log_info("measurement_synth: {format(nrow(measurement_synth), big.mark=',')} rows")

saveRDS(measurement_synth, here::here("data", "temp_synth", "synth_measurement.rds"))
log_info("=== SECTION 4 COMPLETE ===")

# ============================================================
# SECTION 5 (v2): write to Parquet, upload to MinIO, cleanup.
#   FIX: v1's "skip if already in bucket" idempotency check was
#   wrong for this use case — it would have silently prevented
#   the new v2 data from ever overwriting the old v1 data. This
#   version always uploads (overwrites), matching the intent of
#   "regenerate the synthetic dataset."
#   is_severe is dropped HERE — internal synthesis mechanism only,
#   never exposed as a feature (see header note).
# ============================================================
library(paws)
source(here::here("global_config.R"))

log_info("=== SECTION 5 ({SYNTH_VERSION}): write + upload to MinIO ===")

syn_person_final <- new_person %>%
  mutate(subject_id = as.integer(subject_id), gender = as.character(gender),
         is_deceased = as.character(is_deceased))
syn_visit_final <- visit_synth %>%
  select(-is_severe) %>%   # internal-only, never exposed downstream
  mutate(subject_id = as.integer(subject_id), hadm_id = as.integer(hadm_id))
syn_condition_final   <- condition_synth  %>% mutate(subject_id = as.integer(subject_id), hadm_id = as.integer(hadm_id))
syn_measurement_final <- measurement_synth %>% mutate(subject_id = as.integer(subject_id), hadm_id = as.integer(hadm_id))

out_dir <- here::here("data", "temp_synth")
arrow::write_parquet(syn_person_final,      file.path(out_dir, "syn_person.parquet"))
arrow::write_parquet(syn_visit_final,       file.path(out_dir, "syn_visit.parquet"))
arrow::write_parquet(syn_condition_final,   file.path(out_dir, "syn_condition.parquet"))
arrow::write_parquet(syn_measurement_final, file.path(out_dir, "syn_measurement.parquet"))

table_names <- c("syn_person", "syn_visit", "syn_condition", "syn_measurement")
local_sizes <- file.info(file.path(out_dir, paste0(table_names, ".parquet")))$size
log_info("Local Parquet written — total {round(sum(local_sizes)/1e6, 1)} MB")

s3_client <- paws::s3(config = list(
  credentials = list(creds = list(
    access_key_id     = Sys.getenv("CLOUD_ACCESS_KEY_ID"),
    secret_access_key = Sys.getenv("CLOUD_SECRET_ACCESS_KEY"))),
  endpoint = Sys.getenv("CLOUD_ENDPOINT"),
  region   = Sys.getenv("CLOUD_REGION", "us-east-1")
))

for (tbl in table_names) {
  key <- paste0(tbl, ".parquet")
  fp  <- file.path(out_dir, key)
  s3_client$put_object(Bucket = Sys.getenv("CLOUD_BUCKET_NAME"), Key = key,
                       Body = readBin(fp, "raw", n = file.info(fp)$size))
  log_info("Uploaded (overwrite): {key} ({round(file.info(fp)$size/1e6,1)} MB)")
}

log_info("=== SECTION 5 COMPLETE — v2 tables live in MinIO, overwriting v1 ===")