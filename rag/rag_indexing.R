# ============================================================
# rag/rag_indexing.R
# r-healthcare-readmission — Stage 6
# ============================================================
# Creates 8 synthetic clinical guideline documents, chunks them,
# builds a TF-IDF index, stores chunks + index in local DuckDB,
# and records rag_index_metadata governance.
#
# Retrieval design (40/30/30 hybrid):
#   40% TF-IDF cosine similarity   — full text semantic match
#   30% Keyword density score      — exact term frequency in chunk
#   30% ICD tag overlap            — structured metadata match
#
# No new packages: base R + dplyr for all text processing.
# The TF-IDF matrix is saved as rag/tfidf_index_v1.rds alongside
# the DuckDB chunk texts — matrix for similarity math, DuckDB for
# text display and governance queries.
# ============================================================

library(here); library(DBI); library(dplyr); library(digest); library(logger)

source(here::here("global_config.R"))
source(here::here("r_scripts", "governance_helpers.R"))

log_info("=== rag_indexing.R: STAGE 6 ===")

INDEX_VERSION    <- "v1"
CHUNK_SIZE_WORDS <- 150
CHUNK_OVERLAP    <- 30

# ============================================================
# STEP 1 — Create synthetic clinical guideline documents
# ============================================================
dir.create(here::here("rag", "guidelines"), recursive = TRUE, showWarnings = FALSE)

guidelines <- list(
  
  hf_discharge_protocol = list(
    icd_tags = "I50,428",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Heart Failure 30-Day Readmission Prevention Protocol

Section 1: Discharge Criteria
Patients with heart failure should meet the following before discharge: clinical
stability for 24 hours (no IV diuretics, stable weight, stable vital signs),
resting heart rate below 100 bpm, systolic blood pressure above 80 mmHg,
ambulatory oxygen saturation above 92%, and documented patient education
completion. Premature discharge before achieving clinical stability is a leading
cause of 30-day readmission.

Section 2: Medication Reconciliation at Discharge
All patients should be discharged on evidence-based heart failure therapies
including ACE inhibitor or ARB, beta-blocker, and aldosterone antagonist unless
contraindicated. Review and reconcile all home medications before discharge.
Provide written medication list to patient. Confirm the patient can afford and
access all discharge medications before leaving the facility.

Section 3: Follow-Up Appointment Scheduling
Schedule a follow-up appointment within 7 days of discharge — not 30 days.
Studies consistently show that patients with a scheduled follow-up within 7 days
have significantly lower 30-day readmission rates. Confirm the appointment date
and location in writing before the patient leaves. Provide an after-hours
contact number for the first 72 hours post-discharge.

Section 4: Patient Education Requirements
Document that the patient received education on: daily weight monitoring
(alert provider for 2-pound gain in one day or 5-pound gain in one week),
fluid restriction, sodium restriction, medication purpose and side effects,
and when to seek emergency care. Education should be provided to a family
member or caregiver when possible."
  ),
  
  copd_readmission_prevention = list(
    icd_tags = "J44,491,492,496",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

COPD Readmission Prevention Discharge Protocol

Section 1: Discharge Criteria for COPD Exacerbation
A patient recovering from a COPD exacerbation should meet all criteria before
discharge: return to pre-exacerbation baseline spirometry or clinical function,
inhaler technique verified and documented, oxygen saturation adequate on home
oxygen setting (if applicable), and no requirement for supplemental bronchodilators
more frequently than every 4 hours. Patients admitted for severe exacerbations
should have a minimum 2-day observation period after clinical stabilization.

Section 2: Inhaler Education and Technique Verification
Before discharge, a respiratory therapist or trained nurse must observe the
patient demonstrating correct inhaler technique for all prescribed inhalers.
Document the inhaler technique assessment in the medical record. Provide written
step-by-step inhaler instructions. Arrange for inhaler spacers when appropriate.

Section 3: COPD Action Plan
Every COPD patient should leave with a personalized written COPD Action Plan
describing: green zone (stable, continue usual medications), yellow zone
(worsening symptoms, initiate rescue medications), and red zone (emergency,
call 911). The action plan should include clear triggers and responses.

Section 4: Post-Discharge Pulmonary Rehabilitation
Pulmonary rehabilitation reduces COPD readmissions by up to 40%. Refer all
eligible patients to a supervised pulmonary rehabilitation program within
4 weeks of discharge. Ensure the referral is placed before the patient leaves
the hospital."
  ),
  
  ckd_management_discharge = list(
    icd_tags = "N18,585",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Chronic Kidney Disease Discharge and Readmission Prevention Protocol

Section 1: Nephrology Follow-Up Requirements
Patients with CKD Stage 3b or higher (eGFR < 45) admitted for any cause should
have nephrology follow-up scheduled within 30 days of discharge. Patients with
acute-on-chronic kidney disease should have follow-up within 7 days. Ensure
serum creatinine, BUN, electrolytes, and urinalysis are ordered for the
follow-up visit before discharge.

Section 2: Medication Management in CKD
Review all medications for nephrotoxicity before discharge. Avoid NSAIDs,
nephrotoxic antibiotics, and contrast agents unless benefits clearly outweigh
risks. Adjust doses of renally-cleared medications for current GFR. Check
potassium-sparing medications carefully in patients with reduced eGFR.

Section 3: Fluid and Dietary Counseling
Provide dietary counseling on potassium, phosphorus, and sodium restriction
appropriate to the patient's CKD stage. Patients with CKD Stage 4 or 5 should
receive formal renal dietitian consultation before discharge. Document dietary
education in the medical record.

Section 4: Emergency Return Criteria
Instruct patients to return to the emergency department for: decreased urine
output, unexpected weight gain greater than 3 pounds in 24 hours, confusion,
muscle weakness, or irregular heartbeat — all potential signs of electrolyte
imbalance or acute decompensation requiring immediate evaluation."
  ),
  
  sepsis_recovery_care = list(
    icd_tags = "A41,038",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Post-Sepsis Discharge and Recovery Protocol

Section 1: Post-Sepsis Syndrome Awareness
A significant proportion of sepsis survivors experience Post-Sepsis Syndrome:
cognitive impairment, fatigue, sleep disturbance, anxiety, depression, and
increased susceptibility to future infections. Screen for these symptoms before
discharge and document findings. Inform the patient and family that these
symptoms are common, expected, and treatable.

Section 2: Antibiotic Completion and Infection Source Control
Ensure all antibiotic courses are completed as prescribed. Do not discharge
patients who still require IV antibiotics without clear discharge antibiotic
plan and follow-up. Document the source of infection and confirm the source
has been adequately controlled before discharge.

Section 3: Functional Assessment and Rehabilitation Referral
Assess functional status compared to pre-sepsis baseline before discharge.
Patients with significant functional decline should receive physical therapy
evaluation and referral to inpatient or outpatient rehabilitation. Document
the functional status assessment.

Section 4: Follow-Up Care Coordination
Schedule primary care follow-up within 7 days of discharge. Provide a
comprehensive discharge summary to the receiving primary care provider,
including: precipitating infection source, organisms isolated, antimicrobials
used, peak organ dysfunction reached, and ongoing recovery needs. Patients
with ICU stays should be referred to a post-ICU clinic when available."
  ),
  
  acute_mi_secondary_prevention = list(
    icd_tags = "I21,410",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Acute Myocardial Infarction Secondary Prevention and Discharge Protocol

Section 1: Evidence-Based Discharge Medications
All patients discharged after acute MI without contraindications should receive:
dual antiplatelet therapy (aspirin + P2Y12 inhibitor), high-intensity statin
therapy, ACE inhibitor or ARB, and beta-blocker. Document the rationale for
any omissions. Verify the patient understands the critical importance of not
stopping antiplatelet therapy without consulting their cardiologist.

Section 2: Cardiac Rehabilitation Referral
Cardiac rehabilitation reduces post-MI mortality by up to 25% and readmission
rates significantly. Refer all eligible patients to cardiac rehabilitation before
discharge. Ensure the referral is submitted and confirmed. Do not rely on the
patient to self-refer.

Section 3: Risk Factor Modification Counseling
Before discharge, document counseling on: smoking cessation (prescribe
pharmacotherapy for all smokers), blood pressure management, diabetes
management if applicable, dietary modification, physical activity guidance,
and weight management. Provide written materials.

Section 4: Follow-Up Scheduling
Schedule cardiology follow-up within 14 days of discharge for all STEMI
patients and within 7 days for high-risk NSTEMI patients. Ensure the patient
has a named cardiologist contact and after-hours instructions before leaving
the hospital."
  ),
  
  medication_reconciliation_protocol = list(
    icd_tags = "general",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Medication Reconciliation at Hospital Discharge — General Protocol

Section 1: Reconciliation Requirements
Complete medication reconciliation is required for every patient at discharge.
The reconciliation must compare: medications on admission, medications changed
during hospitalization, and planned discharge medications. A pharmacist-led
reconciliation reduces medication errors at discharge by up to 50% and
significantly lowers readmission rates attributable to medication errors.

Section 2: High-Risk Medication Classes
Patients discharged on any of the following require enhanced counseling and
follow-up: anticoagulants (warfarin, DOACs), insulin and other hypoglycemics,
immunosuppressants, narrow-therapeutic-index medications (digoxin, lithium,
phenytoin), and opioids. Document explicit instructions for each high-risk
medication class.

Section 3: Prescription Provision Before Discharge
Do not discharge patients with prescriptions unfilled or uncertain. For patients
with cost concerns, work with the social worker and pharmacy to identify
patient assistance programs. A patient who cannot afford their discharge
medications will not take them — this is a leading preventable cause of
30-day readmission.

Section 4: Documentation Requirements
The discharge medication list provided to the patient must match the medication
list provided to the receiving provider. Any discrepancy is a medication
reconciliation error that must be corrected before discharge. Document the
name, dose, route, frequency, and duration for every discharge medication."
  ),
  
  high_risk_readmission_criteria = list(
    icd_tags = "general",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

High-Risk Readmission Identification and Enhanced Discharge Protocol

Section 1: Risk Factor Identification
Patients at highest risk for 30-day readmission share the following
characteristics: three or more prior hospitalizations in the past 12 months,
multiple chronic conditions (three or more), prior 30-day readmission history,
active substance use disorder, homelessness or housing instability, inadequate
social support, low health literacy, and poor medication adherence history.
Identify high-risk patients within 24 hours of admission to allow time for
enhanced discharge planning.

Section 2: Enhanced Discharge Planning for High-Risk Patients
High-risk patients require enhanced discharge planning including: social work
consultation, pharmacy counseling, discharge navigator assignment, caregiver
training, and post-discharge phone call protocol. Enhanced planning should
begin at admission, not on the day of discharge.

Section 3: Transitional Care Programs
Enroll high-risk patients in a transitional care program before discharge.
Evidence-based transitional care programs that include a home visit within
48 hours of discharge reduce readmissions by up to 30% in high-risk populations.
Ensure program enrollment is confirmed — not just referred — before discharge.

Section 4: Post-Discharge Phone Call Protocol
A structured post-discharge phone call at 48 to 72 hours after discharge
catches early warning signs before they become emergencies. The call should
assess: medication adherence, symptoms, follow-up appointment attendance,
and understanding of when to seek care. Document all phone contact attempts
and outcomes in the medical record."
  ),
  
  care_transitions_protocol = list(
    icd_tags = "general",
    text = "SYNTHETIC PORTFOLIO DOCUMENT — NOT FOR CLINICAL USE

Safe Care Transitions and Continuity of Care Protocol

Section 1: Discharge Summary Requirements
A complete discharge summary must be available to the receiving provider within
24 hours of discharge. The summary must include: admitting diagnosis, hospital
course summary, procedures performed, test results requiring follow-up,
discharge medications with changes highlighted, pending results and responsible
follow-up provider, follow-up appointments scheduled, and patient education
provided. Incomplete discharge summaries are a leading cause of post-discharge
complications and avoidable readmissions.

Section 2: Care Coordination for Complex Patients
Patients with multiple conditions, multiple providers, or significant functional
limitations require formal care coordination. Assign a care coordinator or case
manager for: patients with 3 or more chronic conditions, patients requiring
home health services, patients with new diagnoses requiring ongoing management,
and patients with history of readmission.

Section 3: Direct Communication with Receiving Providers
For high-risk discharges, direct verbal communication between the discharging
physician and the receiving primary care provider significantly reduces
readmission rates compared to written documentation alone. Document all direct
communications. Do not assume the receiving provider has read the discharge
summary.

Section 4: Patient Understanding Assessment
Before discharge, use a teach-back method to confirm the patient can accurately
describe: their primary diagnosis, the name and purpose of each discharge
medication, their follow-up appointment date and location, and three signs
that should prompt them to seek emergency care. Document teach-back assessment
results. Patients who cannot complete teach-back require additional education
or caregiver support."
  )
)

# ── Write guideline files ──────────────────────────────────
for (name in names(guidelines)) {
  fp <- here::here("rag", "guidelines", paste0(name, ".txt"))
  writeLines(guidelines[[name]]$text, fp)
}
log_info("Written {length(guidelines)} guideline documents to rag/guidelines/")

# ============================================================
# STEP 2 — Chunk documents (150 words, 30-word overlap)
# ============================================================
STOP_WORDS <- c("a","an","the","and","or","but","in","on","at","to","for",
                "of","with","by","from","is","are","was","were","be","been",
                "has","have","had","do","does","did","will","would","could",
                "should","may","might","not","no","this","that","these","those",
                "it","its","as","if","than","so","all","each","any","which",
                "who","their","they","them","we","our","you","your","he","she")

tokenize_text <- function(text) {
  words <- strsplit(tolower(gsub("[^a-zA-Z\\s]", " ", text)), "\\s+")[[1]]
  words <- words[nchar(words) > 2 & !words %in% STOP_WORDS]
  words[words != ""]
}

chunk_text <- function(text, chunk_size = CHUNK_SIZE_WORDS, overlap = CHUNK_OVERLAP) {
  words <- strsplit(trimws(text), "\\s+")[[1]]
  if (length(words) <= chunk_size) return(list(trimws(paste(words, collapse = " "))))
  chunks <- list()
  start  <- 1
  while (start <= length(words)) {
    end <- min(start + chunk_size - 1, length(words))
    chunks[[length(chunks) + 1]] <- trimws(paste(words[start:end], collapse = " "))
    if (end == length(words)) break
    start <- start + chunk_size - overlap
  }
  chunks
}

all_chunks <- purrr::map_dfr(names(guidelines), function(doc_name) {
  chunks <- chunk_text(guidelines[[doc_name]]$text)
  purrr::imap_dfr(chunks, function(chunk_text, idx) {
    tibble(
      chunk_id  = sprintf("%s_chunk%02d", doc_name, idx),
      doc_name  = doc_name,
      chunk_text = chunk_text,
      icd_tags  = guidelines[[doc_name]]$icd_tags
    )
  })
})
log_info("Chunked {length(guidelines)} documents into {nrow(all_chunks)} chunks")

# ============================================================
# STEP 3 — Build TF-IDF index (pure base R + dplyr)
# ============================================================
chunk_tokens <- lapply(all_chunks$chunk_text, tokenize_text)

# Vocabulary: all terms appearing in at least 2 chunks
all_terms  <- unlist(chunk_tokens)
term_freq  <- table(all_terms)
vocab      <- names(term_freq[term_freq >= 2])
vocab      <- sort(vocab)
log_info("Vocabulary size: {length(vocab)} terms (appearing in >= 2 chunks)")

# IDF: log((N+1) / (df+1)) + 1
N          <- length(chunk_tokens)
df         <- sapply(vocab, function(w) sum(sapply(chunk_tokens, function(t) w %in% t)))
idf        <- log((N + 1) / (df + 1)) + 1

# TF-IDF matrix: nrow = chunks, ncol = vocab
tfidf_matrix <- matrix(0, nrow = N, ncol = length(vocab),
                       dimnames = list(all_chunks$chunk_id, vocab))
for (i in seq_len(N)) {
  tokens <- chunk_tokens[[i]]
  tf     <- table(tokens)
  common <- intersect(names(tf), vocab)
  if (length(common) > 0) {
    tfidf_matrix[i, common] <- as.numeric(tf[common]) / length(tokens) * idf[common]
  }
}
log_info("TF-IDF matrix built: {nrow(tfidf_matrix)} chunks x {ncol(tfidf_matrix)} terms")

# ============================================================
# STEP 4 — Store in DuckDB + save TF-IDF RDS
# ============================================================
con <- get_db_connection()

DBI::dbExecute(con, "DROP TABLE IF EXISTS rag_chunks")
DBI::dbWriteTable(con, "rag_chunks", all_chunks, overwrite = TRUE)
log_info("rag_chunks stored in DuckDB: {nrow(all_chunks)} rows")

source_hash <- digest::digest(paste(sapply(guidelines, function(g) g$text), collapse = ""))

write_rag_index_metadata(con,
                         index_version      = INDEX_VERSION,
                         source_hash        = source_hash,
                         n_documents        = length(guidelines),
                         n_chunks           = nrow(all_chunks),
                         chunking_strategy  = sprintf("fixed %d words, %d word overlap, TF-IDF cosine + keyword density + ICD tag overlap", CHUNK_SIZE_WORDS, CHUNK_OVERLAP),
                         retrieval_strategy = "hybrid: 40% TF-IDF cosine, 30% keyword density, 30% ICD tag overlap",
                         created_by         = Sys.info()[["user"]]
)

close_db_connection(con)

saveRDS(list(matrix = tfidf_matrix, vocab = vocab, idf = idf,
             chunk_ids = all_chunks$chunk_id, icd_tags = all_chunks$icd_tags),
        here::here("rag", sprintf("tfidf_index_%s.rds", INDEX_VERSION)))
log_info("TF-IDF index saved: rag/tfidf_index_{INDEX_VERSION}.rds")

log_info("=== rag_indexing.R COMPLETE ===")
log_info("{length(guidelines)} documents | {nrow(all_chunks)} chunks | {length(vocab)} vocab terms | stored in DuckDB + RDS")