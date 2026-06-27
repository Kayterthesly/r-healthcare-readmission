# ============================================================
# rag/llm_wrapper.R
# r-healthcare-readmission — Stage 6
# ============================================================
# Provides generate_discharge_summary() — the single public
# function of this file. Returns the Section 12 governance
# contract: {summary_text, citations, retrieval_debug,
#            trace_id, model_version, index_version}
#
# ellmer version-robustness (added 2026-06-23):
#   ellmer has changed the Gemini function name across versions.
#   The wrapper detects whichever name is exported at runtime:
#   - chat_gemini       (older ellmer versions)
#   - chat_google_gemini (newer ellmer versions)
#   Falls back to the template if neither is found.
# ============================================================

library(here); library(DBI); library(dplyr); library(digest)
library(uuid); library(logger)

source(here::here("global_config.R"))
source(here::here("r_scripts", "governance_helpers.R"))

ICD_CONDITION_MAP <- list(
  "I50" = "heart failure", "428" = "heart failure",
  "J44" = "COPD", "491" = "COPD", "492" = "COPD", "496" = "COPD",
  "N18" = "chronic kidney disease", "585" = "chronic kidney disease",
  "A41" = "sepsis", "038" = "sepsis",
  "I21" = "acute myocardial infarction", "410" = "acute myocardial infarction"
)

# ── Detect ellmer Gemini function at load time ─────────────────
get_ellmer_gemini_fn <- function() {
  if (requireNamespace("ellmer", quietly = TRUE)) {
    ns <- asNamespace("ellmer")
    for (fn_name in c("chat_gemini", "chat_google_gemini")) {
      if (exists(fn_name, envir = ns, inherits = FALSE)) {
        return(get(fn_name, envir = ns, inherits = FALSE))
      }
    }
  }
  NULL
}
ELLMER_GEMINI_FN <- get_ellmer_gemini_fn()
if (!is.null(ELLMER_GEMINI_FN)) {
  log_info("[rag_wrapper] ellmer Gemini function resolved successfully")
} else {
  log_info("[rag_wrapper] No ellmer Gemini function found — template fallback will be used")
}

cosine_sim <- function(a, b) {
  denom <- sqrt(sum(a^2)) * sqrt(sum(b^2))
  if (denom < 1e-10) return(0)
  sum(a * b) / denom
}

build_query_vector <- function(patient_profile, index) {
  query_terms <- c(
    gsub("_", " ", patient_profile$top_feature_names),
    patient_profile$condition_terms,
    "readmission", "discharge", "prevention", "follow", "medication"
  )
  query_text <- paste(tolower(query_terms), collapse = " ")
  query_tok  <- strsplit(query_text, "\\s+")[[1]]
  vec <- setNames(numeric(length(index$vocab)), index$vocab)
  for (term in query_tok) {
    if (term %in% index$vocab) vec[term] <- vec[term] + 1
  }
  norm <- sum(vec)
  if (norm > 0) vec <- vec / norm * index$idf
  vec
}

retrieve_chunks <- function(patient_profile, index, all_chunks, k = 3) {
  query_vec <- build_query_vector(patient_profile, index)
  query_terms_lower <- unique(unlist(strsplit(tolower(
    paste(c(patient_profile$top_feature_names,
            patient_profile$condition_terms), collapse = " ")), "\\s+")))
  
  scores <- purrr::map_dfr(seq_len(nrow(index$matrix)), function(i) {
    chunk_vec       <- index$matrix[i, ]
    tfidf_score     <- cosine_sim(query_vec, chunk_vec)
    chunk_text_lower <- tolower(all_chunks$chunk_text[i])
    kw_hits  <- sum(sapply(query_terms_lower, function(t) grepl(t, chunk_text_lower, fixed = TRUE)))
    kw_score <- kw_hits / max(length(query_terms_lower), 1)
    chunk_tags   <- strsplit(all_chunks$icd_tags[i], ",")[[1]]
    patient_tags <- patient_profile$icd_families
    icd_score <- if ("general" %in% chunk_tags) {
      0.5
    } else {
      overlap <- sum(sapply(patient_tags, function(pt) any(startsWith(chunk_tags, substr(pt,1,3)))))
      overlap / max(length(patient_tags), 1)
    }
    tibble(chunk_idx = i, tfidf_score = tfidf_score,
           kw_score = kw_score, icd_score = icd_score,
           combined = 0.40*tfidf_score + 0.30*kw_score + 0.30*icd_score)
  })
  
  top_k <- scores %>% arrange(desc(combined)) %>% slice_head(n = k)
  top_k$chunk_text <- all_chunks$chunk_text[top_k$chunk_idx]
  top_k$chunk_id   <- all_chunks$chunk_id[top_k$chunk_idx]
  top_k$doc_name   <- all_chunks$doc_name[top_k$chunk_idx]
  top_k
}

build_prompt <- function(patient_profile, retrieved_chunks) {
  guideline_context <- paste(purrr::imap_chr(seq_len(nrow(retrieved_chunks)), function(i, ...) {
    sprintf("[GUIDELINE %d — %s]\n%s", i,
            gsub("_", " ", retrieved_chunks$doc_name[i]),
            retrieved_chunks$chunk_text[i])
  }), collapse = "\n\n")
  
  sprintf(
    "You are a clinical decision support assistant helping prepare a discharge summary for a patient at high risk of 30-day hospital readmission.

PATIENT PROFILE:
- Predicted 30-day readmission risk: %.1f%%
- Key risk factors: %s
- Primary condition families: %s
- Length of stay: %.1f days
- Prior admissions: %d

RELEVANT CLINICAL GUIDELINES:
%s

INSTRUCTIONS:
Write a concise, actionable discharge summary recommendation (150-200 words) for the clinical team.
Focus on the 3-5 most important actions to reduce readmission risk for THIS patient specifically.
Cite the specific guideline sections you draw from using the format [GUIDELINE N, Section X].
End with a CITATIONS line listing all guideline documents cited.
Do not include information not present in the guidelines above.
Begin with: DISCHARGE RECOMMENDATION:
End with: CITATIONS: [list the guideline document names cited]",
    patient_profile$risk_pct,
    paste(gsub("_", " ", patient_profile$top_feature_names), collapse = ", "),
    paste(patient_profile$condition_terms, collapse = ", "),
    patient_profile$los_days,
    patient_profile$n_prior_admissions,
    guideline_context
  )
}

generate_template_summary <- function(patient_profile, retrieved_chunks) {
  conditions <- paste(patient_profile$condition_terms, collapse = " and ")
  docs       <- paste(unique(retrieved_chunks$doc_name[1:min(2,nrow(retrieved_chunks))]),
                      collapse = " and ")
  list(
    summary_text = sprintf(
      "DISCHARGE RECOMMENDATION (TEMPLATE — GEMINI UNAVAILABLE):
Patient presents with %.1f%% predicted 30-day readmission risk. Primary risk factors include %s. Relevant guidelines retrieved: %s. Actions recommended: (1) Schedule follow-up within 7 days [GUIDELINE 1, Section 3]. (2) Complete medication reconciliation before discharge [GUIDELINE 2, Section 1]. (3) Provide written discharge action plan with emergency return criteria [GUIDELINE 1, Section 4]. (4) Enroll in transitional care program if high-risk criteria met [GUIDELINE 3, Section 3].",
      patient_profile$risk_pct, conditions, docs
    ),
    citations     = unique(retrieved_chunks$doc_name[1:min(3,nrow(retrieved_chunks))]),
    fallback_used = TRUE,
    llm_model     = "template_fallback"
  )
}

# ============================================================
# PUBLIC FUNCTION: generate_discharge_summary()
# ============================================================
generate_discharge_summary <- function(
    subject_id, hadm_id, predicted_risk, top_feature_names,
    icd_families, los_days, n_prior_admissions,
    model_version = "v3", index_version = "v1") {
  
  index_path <- here::here("rag", sprintf("tfidf_index_%s.rds", index_version))
  if (!file.exists(index_path)) stop("RAG index not found. Run rag/rag_indexing.R first.")
  index <- readRDS(index_path)
  
  con_db     <- get_db_connection()
  all_chunks <- DBI::dbGetQuery(con_db, "SELECT chunk_id, doc_name, chunk_text, icd_tags FROM rag_chunks")
  close_db_connection(con_db)
  
  condition_terms <- unique(unlist(lapply(icd_families, function(fam) {
    matches <- ICD_CONDITION_MAP[startsWith(names(ICD_CONDITION_MAP), substr(fam,1,3))]
    if (length(matches) > 0) unlist(matches) else fam
  })))
  
  patient_profile <- list(
    risk_pct           = round(predicted_risk * 100, 1),
    top_feature_names  = top_feature_names,
    icd_families       = icd_families,
    condition_terms    = if (length(condition_terms) == 0) c("readmission","general") else condition_terms,
    los_days           = los_days,
    n_prior_admissions = n_prior_admissions
  )
  
  retrieved <- retrieve_chunks(patient_profile, index, all_chunks, k = 3)
  log_info("[RAG] Retrieved {nrow(retrieved)} chunks for subject {subject_id}")
  
  api_key  <- Sys.getenv("GOOGLE_API_KEY")
  trace_id <- uuid::UUIDgenerate()
  
  if (nchar(api_key) > 10 && !is.null(ELLMER_GEMINI_FN)) {
    prompt       <- build_prompt(patient_profile, retrieved)
    request_hash <- digest::digest(prompt)
    tryCatch({
      chat         <- ELLMER_GEMINI_FN(
        system_prompt = "You are a clinical decision support assistant specializing in hospital readmission prevention. Be concise, cite your sources, and focus on actionable recommendations.",
        model         = "gemini-2.0-flash"
      )
      raw_response  <- chat$chat(prompt)
      response_hash <- digest::digest(raw_response)
      citation_line <- regmatches(raw_response, regexpr("CITATIONS:.*", raw_response))
      citations     <- if (length(citation_line) > 0) gsub("CITATIONS:\\s*","",citation_line) else
        paste(unique(retrieved$doc_name), collapse = ", ")
      result <- list(summary_text = raw_response, citations = citations,
                     fallback_used = FALSE, llm_model = "gemini-2.0-flash",
                     request_hash = request_hash, response_hash = response_hash)
    }, error = function(e) {
      log_warn("[RAG] Gemini API error: {conditionMessage(e)} — using template fallback")
      r <- generate_template_summary(patient_profile, retrieved)
      r$request_hash  <- digest::digest(build_prompt(patient_profile, retrieved))
      r$response_hash <- digest::digest(r$summary_text)
      result <<- r
    })
  } else {
    if (nchar(api_key) <= 10) log_info("[RAG] No GOOGLE_API_KEY found — using template fallback")
    if (is.null(ELLMER_GEMINI_FN)) log_info("[RAG] No ellmer Gemini function available — using template fallback")
    result <- generate_template_summary(patient_profile, retrieved)
    result$request_hash  <- digest::digest(build_prompt(patient_profile, retrieved))
    result$response_hash <- digest::digest(result$summary_text)
  }
  
  gov_con <- get_db_connection()
  write_llm_call_log(gov_con,
                     trace_id = trace_id, model_version = model_version, index_version = index_version,
                     llm_model = result$llm_model, request_hash = result$request_hash,
                     response_hash = result$response_hash, n_chunks_retrieved = nrow(retrieved),
                     fallback_used = isTRUE(result$fallback_used), created_by = Sys.info()[["user"]])
  close_db_connection(gov_con)
  
  list(summary_text    = result$summary_text,
       citations       = result$citations,
       retrieval_debug = list(top_chunks = retrieved %>%
                                select(chunk_id, doc_name, combined,
                                       tfidf_score, kw_score, icd_score)),
       trace_id        = trace_id,
       model_version   = model_version,
       index_version   = index_version)
}

log_info("[rag_wrapper] rag/llm_wrapper.R loaded — generate_discharge_summary() ready.")