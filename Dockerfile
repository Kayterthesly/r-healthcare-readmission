# Healthcare Readmission Pipeline — Railway Deployment
# rocker/r-ver:4.4.2 = Ubuntu 22.04 (jammy) — stable, well-tested
FROM rocker/r-ver:4.4.2

# System libraries
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libsodium-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    zlib1g-dev libgit2-dev curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── KEY FIX 1: Override renv repos to Posit Package Manager binary mirror.
# This makes renv::restore() fetch pre-compiled .tar.gz binaries (~2 min)
# instead of compiling 197 packages from source (~25 min, exceeds timeout).
# RENV_CONFIG_REPOS_OVERRIDE takes precedence over renv.lock repository URLs.
ENV RENV_CONFIG_REPOS_OVERRIDE="https://packagemanager.posit.co/cran/__linux__/jammy/latest"

# ── KEY FIX 2: renv.lock was generated on R 4.5.2 (Windows); Docker runs
# 4.4.2. Setting this skips the version-mismatch abort so restore proceeds.
ENV RENV_CONFIG_R_VERSION_CHECK=FALSE

# ── Standard renv opt-in required for non-interactive restore
ENV RENV_CONSENT=1

# Copy renv infrastructure first (separate Docker layer — cached if unchanged)
COPY renv.lock renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/.gitignore renv/.gitignore
COPY renv/settings.json renv/settings.json
COPY .Rprofile .Rprofile

# Install renv then restore all packages from Posit PM binaries
RUN R -e "install.packages('renv', repos = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')"
RUN R -e "renv::restore(prompt = FALSE)"

# Copy remaining project files
COPY . .

# Runtime directories
RUN mkdir -p /app/data /app/logs

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

CMD Rscript -e "source('global_config.R'); pr <- plumber::plumb('api/plumber.R'); pr\$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT', '8080')))"