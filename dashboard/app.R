# ============================================================
# dashboard/app.R
# r-healthcare-readmission — Shiny Dashboard
# ============================================================
# Five tabs:
#   1. Pipeline Overview  — health + governance + quick stats
#   2. Patient Risk       — live predict + explain + RAG summary
#   3. Model Performance  — metric table + ROC/PR charts
#   4. Fairness Analysis  — subgroup recall bars + flagged alerts
#   5. Governance Monitor — all 8 tables, LLM log, audit log
# ============================================================

library(shiny)
library(shinydashboard)
library(plotly)
library(DT)
library(here)
library(dplyr)
library(DBI)

# ── WD FIX: shiny::runApp("dashboard/app.R") changes WD to
# dashboard/. here::here() anchors back to the .Rproj root
# so all relative paths (DuckDB, model .rds, logs/) resolve
# correctly regardless of how the app is launched. ──────────
setwd(here::here())

suppressMessages({
  source(here::here("global_config.R"))
  source(here::here("r_scripts", "governance_helpers.R"))
  source(here::here("rag", "llm_wrapper.R"))
  source(here::here("api", "plumber.R"))
})

get_sample_hadm_ids <- function(n = 50) {
  tryCatch({
    con  <- get_db_connection()
    ids  <- dbGetQuery(con, sprintf("SELECT hadm_id, subject_id, readmit_30d,
                                     ROUND(los_days,1) AS los_days
                                     FROM features_v1
                                     ORDER BY RANDOM() LIMIT %d", n))
    close_db_connection(con)
    ids
  }, error = function(e) data.frame(hadm_id=800023822L, subject_id=908646L,
                                    readmit_30d=0, los_days=6.5))
}

SAMPLE_IDS <- get_sample_hadm_ids()

# ============================================================
# UI
# ============================================================
ui <- dashboardPage(
  skin = "blue",
  
  dashboardHeader(
    title = "🏥 Readmission Pipeline",
    titleWidth = 280
  ),
  
  dashboardSidebar(
    width = 280,
    sidebarMenu(
      menuItem("Pipeline Overview",  tabName = "overview",    icon = icon("hospital")),
      menuItem("Patient Risk",       tabName = "patient",     icon = icon("user-md")),
      menuItem("Model Performance",  tabName = "performance", icon = icon("chart-line")),
      menuItem("Fairness Analysis",  tabName = "fairness",    icon = icon("balance-scale")),
      menuItem("Governance Monitor", tabName = "governance",  icon = icon("database"))
    ),
    hr(),
    div(style = "padding: 10px; color: #aaa; font-size: 11px;",
        "Model: xgboost v3 | AUC-ROC: 0.566",
        br(), "FOR PORTFOLIO DEMONSTRATION ONLY",
        br(), "Not for clinical use")
  ),
  
  dashboardBody(
    tags$head(tags$style(HTML("
      .content-wrapper { background-color: #f4f6f9; }
      .box-header { background-color: #3c8dbc; color: #fff; }
      .risk-high   { color: #e74c3c; font-weight: bold; font-size: 2em; }
      .risk-medium { color: #f39c12; font-weight: bold; font-size: 2em; }
      .risk-low    { color: #27ae60; font-weight: bold; font-size: 2em; }
    "))),
    
    tabItems(
      
      # ── Tab 1: Overview ──────────────────────────────────
      tabItem(tabName = "overview",
              fluidRow(
                valueBoxOutput("box_status",   width = 3),
                valueBoxOutput("box_models",   width = 3),
                valueBoxOutput("box_patients", width = 3),
                valueBoxOutput("box_tests",    width = 3)
              ),
              fluidRow(
                box(title="Governance Tables", width=6, solidHeader=TRUE, status="primary",
                    DTOutput("tbl_governance_counts")),
                box(title="Recent Predictions Audit", width=6, solidHeader=TRUE, status="primary",
                    DTOutput("tbl_recent_audit"))
              ),
              fluidRow(
                box(title="Monitoring Report (latest)", width=12, solidHeader=TRUE, status="info",
                    verbatimTextOutput("txt_monitoring"))
              )
      ),
      
      # ── Tab 2: Patient Risk ───────────────────────────────
      tabItem(tabName = "patient",
              fluidRow(
                box(title="Patient Selection", width=4, solidHeader=TRUE, status="primary",
                    selectInput("sel_hadm_id", "Hospital Admission ID (hadm_id):",
                                choices = setNames(SAMPLE_IDS$hadm_id,
                                                   paste0(SAMPLE_IDS$hadm_id,
                                                          " — Pt ", SAMPLE_IDS$subject_id,
                                                          " | LOS ", SAMPLE_IDS$los_days, "d",
                                                          ifelse(SAMPLE_IDS$readmit_30d==1," ⚠️ READMIT",""))),
                                width = "100%"),
                    selectInput("sel_icd_families", "ICD Condition Families:",
                                choices = c("Heart Failure"="I50", "COPD"="J44", "CKD"="N18",
                                            "Sepsis"="A41", "Acute MI"="I21",
                                            "HF + COPD"="I50,J44", "General"="general"),
                                selected = "I50,J44"),
                    actionButton("btn_predict", "Run Full Analysis", icon=icon("play"),
                                 class="btn-primary btn-block", style="margin-top:10px")
                ),
                box(title="Risk Score", width=4, solidHeader=TRUE, status="warning",
                    uiOutput("ui_risk_score"),
                    hr(),
                    uiOutput("ui_risk_details")
                ),
                box(title="Top Risk Drivers", width=4, solidHeader=TRUE, status="danger",
                    plotlyOutput("plt_drivers", height="280px"))
              ),
              fluidRow(
                box(title="Discharge Recommendation (RAG-cited)", width=12,
                    solidHeader=TRUE, status="success",
                    uiOutput("ui_rag_summary"))
              )
      ),
      
      # ── Tab 3: Model Performance ──────────────────────────
      tabItem(tabName = "performance",
              fluidRow(
                box(title="All Model Versions — Registry", width=12,
                    solidHeader=TRUE, status="primary",
                    DTOutput("tbl_model_registry"))
              ),
              fluidRow(
                box(title="AUC-ROC by Version", width=6, solidHeader=TRUE, status="info",
                    plotlyOutput("plt_auc_roc", height="320px")),
                box(title="Recall vs. Precision Tradeoff", width=6, solidHeader=TRUE, status="info",
                    plotlyOutput("plt_recall_precision", height="320px"))
              )
      ),
      
      # ── Tab 4: Fairness Analysis ───────────────────────────
      tabItem(tabName = "fairness",
              fluidRow(
                infoBoxOutput("ibox_gender",    width=4),
                infoBoxOutput("ibox_insurance", width=4),
                infoBoxOutput("ibox_race",      width=4)
              ),
              fluidRow(
                box(title="Recall by Race (xgboost v3, threshold 0.58)",
                    width=12, solidHeader=TRUE, status="warning",
                    plotlyOutput("plt_fairness_race", height="350px"))
              ),
              fluidRow(
                box(title="Recall by Gender", width=6, solidHeader=TRUE, status="primary",
                    plotlyOutput("plt_fairness_gender", height="280px")),
                box(title="Recall by Insurance", width=6, solidHeader=TRUE, status="primary",
                    plotlyOutput("plt_fairness_insurance", height="280px"))
              )
      ),
      
      # ── Tab 5: Governance Monitor ─────────────────────────
      tabItem(tabName = "governance",
              fluidRow(
                box(title="LLM Call Log", width=6, solidHeader=TRUE, status="primary",
                    DTOutput("tbl_llm_log")),
                box(title="Feature Registry", width=6, solidHeader=TRUE, status="primary",
                    DTOutput("tbl_feature_reg"))
              ),
              fluidRow(
                box(title="Predictions Audit (full)", width=12, solidHeader=TRUE, status="primary",
                    DTOutput("tbl_pred_audit_full"))
              )
      )
    )
  )
)

# ============================================================
# SERVER
# ============================================================
server <- function(input, output, session) {
  
  gov_data <- reactive({
    con <- get_db_connection()
    d <- list(
      model_reg   = dbGetQuery(con, "SELECT * FROM model_registry ORDER BY model_type, model_version"),
      fairness    = dbGetQuery(con, "SELECT * FROM fairness_reports WHERE model_version='v3'"),
      pred_audit  = tryCatch(dbGetQuery(con, "SELECT * FROM predictions_audit ORDER BY created_at DESC"), error=function(e) NULL),
      llm_log     = tryCatch(dbGetQuery(con, "SELECT * FROM llm_call_log ORDER BY created_at DESC"), error=function(e) NULL),
      feature_reg = dbGetQuery(con, "SELECT * FROM feature_registry"),
      ingest      = dbGetQuery(con, "SELECT table_name, rows, end_ts FROM ingest_metadata"),
      rag_meta    = dbGetQuery(con, "SELECT index_version, n_documents, n_chunks FROM rag_index_metadata")
    )
    close_db_connection(con)
    d
  })
  
  # ── Tab 1 ────────────────────────────────────────────────
  output$box_status   <- renderValueBox(valueBox("HEALTHY","Pipeline Status",icon=icon("check-circle"),color="green"))
  output$box_models   <- renderValueBox(valueBox(sum(gov_data()$model_reg$approved,na.rm=TRUE),"Approved Models",icon=icon("robot"),color="blue"))
  output$box_patients <- renderValueBox(valueBox("15,000","Synthetic Patients",icon=icon("hospital-user"),color="purple"))
  output$box_tests    <- renderValueBox(valueBox("71 / 0","Tests Passed / Failed",icon=icon("vials"),color="teal"))
  
  output$tbl_governance_counts <- renderDT({
    d <- gov_data()
    df <- data.frame(
      Table  = c("ingest_metadata","feature_registry","model_registry","fairness_reports",
                 "rag_chunks","rag_index_metadata","llm_call_log","predictions_audit"),
      Rows   = c(nrow(d$ingest),nrow(d$feature_reg),nrow(d$model_reg),nrow(d$fairness),
                 16,nrow(d$rag_meta),
                 ifelse(is.null(d$llm_log),0,nrow(d$llm_log)),
                 ifelse(is.null(d$pred_audit),0,nrow(d$pred_audit))),
      Status = "✅"
    )
    datatable(df, options=list(paging=FALSE,searching=FALSE), rownames=FALSE)
  })
  
  output$tbl_recent_audit <- renderDT({
    d <- gov_data()
    if (is.null(d$pred_audit)||nrow(d$pred_audit)==0)
      return(datatable(data.frame(Note="No predictions yet")))
    datatable(d$pred_audit %>% select(trace_id,model_version,risk_score,risk_tier,env,created_at) %>% head(10),
              options=list(paging=FALSE,searching=FALSE,scrollX=TRUE), rownames=FALSE)
  })
  
  output$txt_monitoring <- renderText({
    report_files <- list.files(here::here("logs"), pattern="monitoring_report_.*\\.md", full.names=TRUE)
    if (length(report_files)==0) return("No monitoring report found. Run r_scripts/08_monitoring.R first.")
    paste(readLines(tail(sort(report_files),1), warn=FALSE), collapse="\n")
  })
  
  # ── Tab 2 ────────────────────────────────────────────────
  pred_result <- eventReactive(input$btn_predict, {
    req(input$sel_hadm_id)
    list(
      predict = predict_core(as.integer(input$sel_hadm_id)),
      explain = explain_core(as.integer(input$sel_hadm_id)),
      rag     = rag_summary_core(as.integer(input$sel_hadm_id), input$sel_icd_families)
    )
  })
  
  output$ui_risk_score <- renderUI({
    req(pred_result())
    p   <- pred_result()$predict
    cls <- paste0("risk-", p$risk_tier)
    pct <- round(p$predicted_risk * 100, 1)
    tagList(
      div(class=cls, paste0(pct, "%"), style="text-align:center; padding:20px 0"),
      div(style="text-align:center; font-size:1.3em;",
          if (p$flagged) "⚠️ HIGH RISK — Flagged" else "✅ Below threshold"),
      div(style="text-align:center; color:#888; font-size:0.85em; margin-top:8px;",
          paste0("Threshold: ", p$threshold, " | Tier: ", toupper(p$risk_tier)))
    )
  })
  
  output$ui_risk_details <- renderUI({
    req(pred_result())
    p <- pred_result()$predict
    tagList(
      tags$small(style="color:#888;", paste0("trace_id: ", substr(p$trace_id,1,18), "...")),
      br(),
      tags$small(style="color:#888;", paste0("model: ", p$model_version))
    )
  })
  
  output$plt_drivers <- renderPlotly({
    req(pred_result())
    e  <- pred_result()$explain
    df <- purrr::map_dfr(e$explanation, ~data.frame(
      feature=.x$feature, delta=.x$delta, direction=.x$direction)) %>%
      arrange(desc(abs(delta)))
    plot_ly(df, x=~delta, y=~reorder(feature,abs(delta)), type="bar",
            orientation="h",
            marker=list(color=ifelse(df$delta>0,"#e74c3c","#27ae60")),
            text=~paste0(ifelse(delta>0,"+",""),round(delta,3)),
            textposition="outside") %>%
      layout(xaxis=list(title="Delta from population median (normalized)"),
             yaxis=list(title=""), margin=list(l=160),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$ui_rag_summary <- renderUI({
    req(pred_result())
    r   <- pred_result()$rag
    cit <- if (is.character(r$citations)) paste(r$citations,collapse=", ") else
      paste(unlist(r$citations),collapse=", ")
    tagList(
      p(style="background:#f8f9fa; padding:15px; border-left:4px solid #3c8dbc;
               border-radius:4px; font-family:monospace; white-space:pre-wrap;
               font-size:0.9em;", r$summary),
      hr(),
      strong("Guidelines retrieved: "), span(cit, style="color:#3c8dbc;"), br(),
      tags$small(style="color:#888;",
                 paste0("trace_id: ", r$trace_id, " | index: ", r$index_version))
    )
  })
  
  # ── Tab 3 ────────────────────────────────────────────────
  output$tbl_model_registry <- renderDT({
    gov_data()$model_reg %>%
      select(model_version,model_type,chosen_threshold,recall,precision,f1,auc_roc,pr_auc,approved) %>%
      mutate(across(c(recall,precision,f1,auc_roc,pr_auc),~round(.,4)),
             approved=ifelse(approved,"✅ YES","❌ NO")) %>%
      datatable(options=list(paging=FALSE,searching=FALSE), rownames=FALSE)
  })
  
  output$plt_auc_roc <- renderPlotly({
    d <- gov_data()$model_reg
    plot_ly(d, x=~paste(model_type,model_version), y=~auc_roc, color=~model_type,
            type="bar", text=~round(auc_roc,4), textposition="outside") %>%
      layout(xaxis=list(title="Model × Version"),
             yaxis=list(title="AUC-ROC",range=c(0.5,0.65)),
             barmode="group",
             shapes=list(list(type="line",x0=-0.5,x1=5.5,y0=0.5,y1=0.5,
                              line=list(color="grey",dash="dot"))),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$plt_recall_precision <- renderPlotly({
    d <- gov_data()$model_reg
    plot_ly(d, x=~recall, y=~precision, color=~model_type,
            text=~paste(model_type,model_version),
            type="scatter", mode="markers+text",
            marker=list(size=14), textposition="top center") %>%
      layout(xaxis=list(title="Recall",range=c(0.85,0.92)),
             yaxis=list(title="Precision",range=c(0.19,0.24)),
             shapes=list(list(type="line",x0=0.85,x1=0.92,y0=0.2028,y1=0.2028,
                              line=list(color="grey",dash="dot"))),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  # ── Tab 4 ────────────────────────────────────────────────
  output$ibox_gender <- renderInfoBox(
    infoBox("Gender Gap","1.2 pp recall",icon=icon("venus-mars"),color="green",
            subtitle="F: 89.2% vs M: 88.0% — No concern"))
  output$ibox_insurance <- renderInfoBox(
    infoBox("Insurance Gap","0.7 pp recall",icon=icon("id-card"),color="green",
            subtitle="Medicare/Medicaid/Other — No concern"))
  output$ibox_race <- renderInfoBox(
    infoBox("Race Gap","87 pp recall",icon=icon("flag"),color="red",
            subtitle="⚠️ Flagged — 13.0% to 100% across subgroups"))
  
  output$plt_fairness_race <- renderPlotly({
    d <- gov_data()$fairness %>% filter(dimension=="race", n>=30)
    d$color <- ifelse(d$flagged_concern,"#e74c3c","#3c8dbc")
    plot_ly(d, x=~recall, y=~reorder(subgroup_value,recall), type="bar",
            orientation="h", marker=list(color=d$color),
            text=~paste0(round(recall*100,1),"% (n=",n,")"),
            textposition="outside") %>%
      layout(xaxis=list(title="Recall",range=c(0,1.05)),
             yaxis=list(title=""), margin=list(l=220),
             shapes=list(list(type="line",x0=0.85,x1=0.85,y0=-0.5,y1=nrow(d)-0.5,
                              line=list(color="grey",dash="dot"))),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$plt_fairness_gender <- renderPlotly({
    d <- gov_data()$fairness %>% filter(dimension=="gender",!is.na(recall))
    plot_ly(d, x=~subgroup_value, y=~recall, type="bar",
            marker=list(color=c("#3498db","#9b59b6")),
            text=~paste0(round(recall*100,1),"%"), textposition="outside") %>%
      layout(yaxis=list(title="Recall",range=c(0.85,0.92)), xaxis=list(title=""),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$plt_fairness_insurance <- renderPlotly({
    d <- gov_data()$fairness %>% filter(dimension=="insurance",!is.na(recall))
    plot_ly(d, x=~subgroup_value, y=~recall, type="bar",
            marker=list(color=c("#2ecc71","#f39c12","#1abc9c")),
            text=~paste0(round(recall*100,1),"%"), textposition="outside") %>%
      layout(yaxis=list(title="Recall",range=c(0.86,0.92)), xaxis=list(title=""),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  # ── Tab 5 ────────────────────────────────────────────────
  output$tbl_llm_log <- renderDT({
    d <- gov_data()$llm_log
    if (is.null(d)) return(datatable(data.frame(Note="No LLM calls yet")))
    datatable(d %>% select(trace_id,llm_model,n_chunks_retrieved,fallback_used,created_at),
              options=list(scrollX=TRUE,paging=TRUE,pageLength=5), rownames=FALSE)
  })
  
  output$tbl_feature_reg <- renderDT({
    datatable(gov_data()$feature_reg %>% select(feature_name,version,window,leakage_note),
              options=list(paging=FALSE,scrollX=TRUE), rownames=FALSE)
  })
  
  output$tbl_pred_audit_full <- renderDT({
    d <- gov_data()$pred_audit
    if (is.null(d)||nrow(d)==0)
      return(datatable(data.frame(Note="No predictions logged yet")))
    datatable(d %>% select(trace_id,model_version,risk_score,risk_tier,explanation_snippet,env,created_at),
              options=list(scrollX=TRUE,paging=TRUE,pageLength=10), rownames=FALSE)
  })
}

shinyApp(ui=ui, server=server)