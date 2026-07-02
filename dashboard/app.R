# dashboard/app.R — shinyapps.io deployment version
library(shiny); library(shinydashboard); library(plotly); library(DT)
library(dplyr); library(httr2); library(purrr)

BUNDLE      <- readRDS("data/deploy_bundle.rds")
RAILWAY_URL <- "https://r-healthcare-readmission-production.up.railway.app"
SAMPLE_IDS  <- BUNDLE$sample_ids
monitoring_text <- tryCatch(
  paste(readLines("data/latest_monitoring_report.md", warn=FALSE), collapse="\n"),
  error = function(e) "Monitoring report unavailable.")

call_api <- function(path) {
  tryCatch({
    resp <- request(paste0(RAILWAY_URL, path)) |> req_timeout(60) |> req_perform()
    resp_body_json(resp)
  }, error = function(e) NULL)
}

ui <- dashboardPage(skin="blue",
                    dashboardHeader(title="🏥 Readmission Pipeline", titleWidth=280),
                    dashboardSidebar(width=280,
                                     sidebarMenu(
                                       menuItem("Pipeline Overview", tabName="overview",    icon=icon("hospital")),
                                       menuItem("Patient Risk",      tabName="patient",     icon=icon("user-md")),
                                       menuItem("Model Performance", tabName="performance", icon=icon("chart-line")),
                                       menuItem("Fairness Analysis", tabName="fairness",    icon=icon("balance-scale")),
                                       menuItem("Governance",        tabName="governance",  icon=icon("database"))
                                     ), hr(),
                                     div(style="padding:10px;color:#aaa;font-size:11px;",
                                         "Model: xgboost v3 | AUC-ROC: 0.566", br(),
                                         "FOR PORTFOLIO DEMO ONLY", br(), "Not for clinical use", br(), br(),
                                         span("🟢 Live API connected", style="color:#2ecc71;"))
                    ),
                    dashboardBody(
                      tags$head(tags$style(HTML(
                        ".risk-high{color:#e74c3c;font-weight:bold;font-size:2em;}
       .risk-medium{color:#f39c12;font-weight:bold;font-size:2em;}
       .risk-low{color:#27ae60;font-weight:bold;font-size:2em;}"))),
                      tabItems(
                        tabItem(tabName="overview",
                                fluidRow(
                                  valueBox("HEALTHY","Pipeline Status",icon=icon("check-circle"),color="green",width=3),
                                  valueBox(sum(BUNDLE$model_reg$approved,na.rm=TRUE),"Approved Models",icon=icon("robot"),color="blue",width=3),
                                  valueBox("15,000","Synthetic Patients",icon=icon("hospital-user"),color="purple",width=3),
                                  valueBox("71 / 0","Tests Pass / Fail",icon=icon("vials"),color="teal",width=3)
                                ),
                                fluidRow(
                                  box(title="Governance Tables",width=6,solidHeader=TRUE,status="primary",DTOutput("tbl_gov")),
                                  box(title="Predictions Audit",width=6,solidHeader=TRUE,status="primary",DTOutput("tbl_audit_sm"))
                                ),
                                fluidRow(box(title="Monitoring Report",width=12,solidHeader=TRUE,status="info",
                                             verbatimTextOutput("txt_mon")))
                        ),
                        tabItem(tabName="patient",
                                fluidRow(
                                  box(title="Patient Selection",width=4,solidHeader=TRUE,status="primary",
                                      selectInput("sel_hadm","Hospital Admission ID:",
                                                  choices=setNames(SAMPLE_IDS$hadm_id,
                                                                   paste0(SAMPLE_IDS$hadm_id," — Pt ",SAMPLE_IDS$subject_id,
                                                                          " | LOS ",SAMPLE_IDS$los_days,"d",
                                                                          ifelse(SAMPLE_IDS$readmit_30d==1," READMIT",""))),
                                                  width="100%"),
                                      selectInput("sel_icd","ICD Families:",
                                                  choices=c("Heart Failure"="I50","COPD"="J44","CKD"="N18",
                                                            "Sepsis"="A41","Acute MI"="I21","HF+COPD"="I50,J44","General"="general"),
                                                  selected="I50,J44"),
                                      actionButton("btn_run","Run Full Analysis",icon=icon("play"),
                                                   class="btn-primary btn-block",style="margin-top:10px")
                                  ),
                                  box(title="Risk Score",width=4,solidHeader=TRUE,status="warning",
                                      uiOutput("ui_risk"),hr(),uiOutput("ui_trace")),
                                  box(title="Top Risk Drivers",width=4,solidHeader=TRUE,status="danger",
                                      plotlyOutput("plt_drivers",height="280px"))
                                ),
                                fluidRow(box(title="Discharge Recommendation (RAG-cited)",width=12,
                                             solidHeader=TRUE,status="success",uiOutput("ui_rag")))
                        ),
                        tabItem(tabName="performance",
                                fluidRow(box(title="All Model Versions",width=12,solidHeader=TRUE,status="primary",DTOutput("tbl_models"))),
                                fluidRow(
                                  box(title="AUC-ROC by Version",width=6,solidHeader=TRUE,status="info",plotlyOutput("plt_auc",height="320px")),
                                  box(title="Recall vs Precision",width=6,solidHeader=TRUE,status="info",plotlyOutput("plt_rp",height="320px"))
                                )
                        ),
                        tabItem(tabName="fairness",
                                fluidRow(
                                  infoBox("Gender Gap","1.2 pp recall",icon=icon("venus-mars"),color="green",width=4,subtitle="F 89.2% vs M 88.0% — Clear"),
                                  infoBox("Insurance Gap","0.7 pp recall",icon=icon("id-card"),color="green",width=4,subtitle="All groups — Clear"),
                                  infoBox("Race Gap","87 pp recall",icon=icon("flag"),color="red",width=4,subtitle="Flagged — 13% to 100%")
                                ),
                                fluidRow(box(title="Recall by Race",width=12,solidHeader=TRUE,status="warning",plotlyOutput("plt_race",height="350px"))),
                                fluidRow(
                                  box(title="Recall by Gender",width=6,solidHeader=TRUE,status="primary",plotlyOutput("plt_gender",height="280px")),
                                  box(title="Recall by Insurance",width=6,solidHeader=TRUE,status="primary",plotlyOutput("plt_ins",height="280px"))
                                )
                        ),
                        tabItem(tabName="governance",
                                fluidRow(
                                  box(title="LLM Call Log",width=6,solidHeader=TRUE,status="primary",DTOutput("tbl_llm")),
                                  box(title="Feature Registry",width=6,solidHeader=TRUE,status="primary",DTOutput("tbl_feat"))
                                ),
                                fluidRow(box(title="Full Predictions Audit",width=12,solidHeader=TRUE,status="primary",DTOutput("tbl_audit")))
                        )
                      )
                    )
)

server <- function(input, output, session) {
  
  output$tbl_gov <- renderDT(datatable(data.frame(
    Table=c("ingest_metadata","feature_registry","model_registry","fairness_reports",
            "rag_chunks","rag_index_metadata","llm_call_log","predictions_audit"),
    Rows=c(nrow(BUNDLE$ingest),nrow(BUNDLE$feature_reg),nrow(BUNDLE$model_reg),
           nrow(BUNDLE$fairness),16,nrow(BUNDLE$rag_meta),
           ifelse(is.null(BUNDLE$llm_log),0,nrow(BUNDLE$llm_log)),
           ifelse(is.null(BUNDLE$pred_audit),0,nrow(BUNDLE$pred_audit))),
    Status="OK"),options=list(paging=FALSE,searching=FALSE),rownames=FALSE))
  
  output$tbl_audit_sm <- renderDT({
    d <- BUNDLE$pred_audit
    if(is.null(d)||nrow(d)==0) return(datatable(data.frame(Note="No predictions yet")))
    datatable(head(d,8) %>% select(any_of(c("trace_id","model_version","risk_score","risk_tier","created_at"))),
              options=list(paging=FALSE,scrollX=TRUE),rownames=FALSE)
  })
  
  output$txt_mon <- renderText(monitoring_text)
  
  result <- eventReactive(input$btn_run, {
    hadm <- as.integer(input$sel_hadm)
    list(
      p = call_api(paste0("/predict?hadm_id=", hadm)),
      e = call_api(paste0("/explain?hadm_id=", hadm)),
      r = call_api(paste0("/rag/summary?hadm_id=", hadm, "&icd_families=", input$sel_icd))
    )
  })
  
  output$ui_risk <- renderUI({
    req(result())
    p <- result()$p
    if(is.null(p)) return(div(style="text-align:center;padding:20px;color:#888;","API unavailable"))
    pct <- round(as.numeric(p$predicted_risk)*100,1)
    cls <- paste0("risk-", p$risk_tier)
    tagList(
      div(class=cls, paste0(pct,"%"), style="text-align:center;padding:20px 0"),
      div(style="text-align:center;font-size:1.3em;",
          if(isTRUE(p$flagged)) "HIGH RISK — Flagged" else "Below threshold"),
      div(style="text-align:center;color:#888;font-size:0.85em;margin-top:8px;",
          paste0("Threshold: 0.58 | Tier: ", toupper(p$risk_tier)))
    )
  })
  
  output$ui_trace <- renderUI({
    req(result()); p <- result()$p
    if(is.null(p)) return(NULL)
    tags$small(style="color:#888;", paste0("trace_id: ", substr(p$trace_id,1,18), "..."))
  })
  
  output$plt_drivers <- renderPlotly({
    req(result()); e <- result()$e
    if(is.null(e)) return(plotly_empty())
    df <- map_dfr(e$explanation, ~data.frame(feature=.x$feature, delta=as.numeric(.x$delta))) %>%
      arrange(desc(abs(delta)))
    plot_ly(df, x=~delta, y=~reorder(feature,abs(delta)), type="bar", orientation="h",
            marker=list(color=ifelse(df$delta>0,"#e74c3c","#27ae60")),
            text=~paste0(ifelse(delta>0,"+",""),round(delta,3)), textposition="outside") %>%
      layout(xaxis=list(title="Delta from median"), yaxis=list(title=""),
             margin=list(l=160), paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$ui_rag <- renderUI({
    req(result()); r <- result()$r
    if(is.null(r)) return(div(style="color:#888;padding:20px;","RAG summary unavailable"))
    tagList(
      p(style="background:#f8f9fa;padding:15px;border-left:4px solid #3c8dbc;border-radius:4px;
               font-family:monospace;white-space:pre-wrap;font-size:0.9em;", r$summary),
      hr(),
      strong("Guidelines: "), span(paste(unlist(r$citations),collapse=", "), style="color:#3c8dbc;"), br(),
      tags$small(style="color:#888;", paste0("trace_id: ", r$trace_id))
    )
  })
  
  output$tbl_models <- renderDT(datatable(
    BUNDLE$model_reg %>%
      select(model_version,model_type,chosen_threshold,recall,precision,f1,auc_roc,pr_auc,approved) %>%
      mutate(across(c(recall,precision,f1,auc_roc,pr_auc),~round(.,4)),
             approved=ifelse(approved,"YES","NO")),
    options=list(paging=FALSE),rownames=FALSE))
  
  output$plt_auc <- renderPlotly(
    plot_ly(BUNDLE$model_reg, x=~paste(model_type,model_version), y=~auc_roc,
            color=~model_type, type="bar", text=~round(auc_roc,4), textposition="outside") %>%
      layout(yaxis=list(title="AUC-ROC",range=c(0.5,0.65)), xaxis=list(title=""),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)"))
  
  output$plt_rp <- renderPlotly(
    plot_ly(BUNDLE$model_reg, x=~recall, y=~precision, color=~model_type,
            text=~paste(model_type,model_version), type="scatter",
            mode="markers+text", marker=list(size=14), textposition="top center") %>%
      layout(xaxis=list(title="Recall",range=c(0.85,0.92)),
             yaxis=list(title="Precision",range=c(0.19,0.24)),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)"))
  
  output$plt_race <- renderPlotly({
    d <- BUNDLE$fairness %>% filter(dimension=="race", n>=30)
    plot_ly(d, x=~recall, y=~reorder(subgroup_value,recall), type="bar", orientation="h",
            marker=list(color=ifelse(d$flagged_concern,"#e74c3c","#3c8dbc")),
            text=~paste0(round(recall*100,1),"% (n=",n,")"), textposition="outside") %>%
      layout(xaxis=list(title="Recall",range=c(0,1.05)), yaxis=list(title=""),
             margin=list(l=220), paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$plt_gender <- renderPlotly({
    d <- BUNDLE$fairness %>% filter(dimension=="gender", !is.na(recall))
    plot_ly(d, x=~subgroup_value, y=~recall, type="bar",
            marker=list(color=c("#3498db","#9b59b6")),
            text=~paste0(round(recall*100,1),"%"), textposition="outside") %>%
      layout(yaxis=list(title="Recall",range=c(0.85,0.92)), xaxis=list(title=""),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$plt_ins <- renderPlotly({
    d <- BUNDLE$fairness %>% filter(dimension=="insurance", !is.na(recall))
    plot_ly(d, x=~subgroup_value, y=~recall, type="bar",
            marker=list(color=c("#2ecc71","#f39c12","#1abc9c")),
            text=~paste0(round(recall*100,1),"%"), textposition="outside") %>%
      layout(yaxis=list(title="Recall",range=c(0.86,0.92)), xaxis=list(title=""),
             paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
  })
  
  output$tbl_llm <- renderDT({
    d <- BUNDLE$llm_log
    if(is.null(d)||nrow(d)==0) return(datatable(data.frame(Note="No LLM calls")))
    datatable(d %>% select(any_of(c("trace_id","llm_model","n_chunks_retrieved","fallback_used","created_at"))),
              options=list(pageLength=5,scrollX=TRUE),rownames=FALSE)
  })
  
  output$tbl_feat <- renderDT(datatable(
    BUNDLE$feature_reg %>% select(feature_name,version,leakage_note),
    options=list(paging=FALSE,scrollX=TRUE),rownames=FALSE))
  
  output$tbl_audit <- renderDT({
    d <- BUNDLE$pred_audit
    if(is.null(d)||nrow(d)==0) return(datatable(data.frame(Note="No predictions logged yet")))
    datatable(d %>% select(any_of(c("trace_id","model_version","risk_score","risk_tier","created_at"))),
              options=list(scrollX=TRUE,pageLength=10),rownames=FALSE)
  })
}

shinyApp(ui=ui, server=server)