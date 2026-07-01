# Healthcare Readmission Pipeline — Railway Deployment
# rocker/r-ver:4.4.2 = Ubuntu 24.04 (Noble) — confirmed from Railway diagnosis
FROM rocker/r-ver:4.4.2

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libsodium-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    zlib1g-dev libgit2-dev curl \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CRITICAL: noble/latest for Ubuntu 24.04 (Noble) — not jammy (22.04)
# Jammy binaries compiled against ICU 70 (libicui18n.so.70)
# Noble system only has ICU 74 (libicui18n.so.74) → crash at startup
# Noble binaries compiled against ICU 74 → match Noble system → works
RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))' \
    >> /usr/local/lib/R/etc/Rprofile.site

ENV RENV_CONFIG_AUTOLOADER_ENABLED=FALSE

RUN Rscript -e "install.packages(c( \
    'here','logger','uuid','digest','jsonlite', \
    'tibble','dplyr','tidyr','purrr','stringr','lubridate' \
))"

RUN Rscript -e "install.packages(c('DBI','duckdb','arrow','paws'))"

RUN Rscript -e "install.packages(c('Matrix','glmnet','xgboost','ROSE'))"

RUN Rscript -e "install.packages(c( \
    'tidymodels','hardhat','parsnip','recipes','rsample', \
    'workflows','tune','yardstick','broom','generics' \
))"

RUN Rscript -e "install.packages(c('plumber','ellmer','httr2'))"

COPY . .
RUN mkdir -p /app/data /app/logs

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

CMD Rscript -e " \
    setwd('/app'); \
    source('global_config.R'); \
    source('r_scripts/governance_helpers.R'); \
    source('rag/llm_wrapper.R'); \
    pr <- plumber::plumb('api/plumber.R'); \
    pr\$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT', '8080')))"