# Healthcare Readmission Pipeline — Railway Deployment
# No renv: installs packages directly from Posit PM binary mirror.
# renv.lock was generated on Windows R 4.5.2 and causes renv::restore()
# to fail on Linux even with RENV_CONFIG_REPOS_OVERRIDE, because renv
# detects the R version mismatch and Windows-specific package metadata.
# Direct installation is more reliable for cross-platform Docker builds.

FROM rocker/r-ver:4.4.2

# System libraries
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libsodium-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    zlib1g-dev libgit2-dev curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Use Posit Package Manager binary mirror for Ubuntu 22.04 (jammy)
# Pre-built binaries = seconds per package instead of minutes from source
RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/latest"))' \
    >> /usr/local/lib/R/etc/Rprofile.site

# ── Group 1: Foundation ──────────────────────────────────────
# Cached as its own layer — only reinstalls if this group changes
RUN Rscript -e "install.packages(c( \
    'here','logger','uuid','digest','jsonlite', \
    'tibble','dplyr','tidyr','purrr','stringr','lubridate' \
))"

# ── Group 2: Database + cloud storage ───────────────────────
RUN Rscript -e "install.packages(c('DBI','duckdb','arrow','paws'))"

# ── Group 3: ML core ─────────────────────────────────────────
RUN Rscript -e "install.packages(c('Matrix','glmnet','xgboost','ROSE'))"

# ── Group 4: tidymodels (components, not meta-package) ───────
RUN Rscript -e "install.packages(c( \
    'hardhat','parsnip','recipes','rsample', \
    'workflows','tune','yardstick','broom','generics' \
))"

# ── Group 5: API + LLM ───────────────────────────────────────
RUN Rscript -e "install.packages(c('plumber','ellmer','httr2'))"

# Copy project files (after package install layers are cached)
COPY . .
RUN mkdir -p /app/data /app/logs

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

CMD Rscript -e "source('global_config.R'); \
    pr <- plumber::plumb('api/plumber.R'); \
    pr\$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT', '8080')))"