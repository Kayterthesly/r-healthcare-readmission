# Healthcare Readmission Forecasting Pipeline — Railway Deployment
FROM rocker/r-ver:4.5.0

# System dependencies for R packages
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsodium-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy renv infrastructure first (for layer caching)
COPY renv.lock renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/.gitignore renv/.gitignore
COPY renv/settings.json renv/settings.json
COPY .Rprofile .Rprofile

# Restore R packages via renv
RUN R -e "install.packages('renv', repos='https://packagemanager.posit.co/cran/latest'); renv::restore()"

# Copy all project files
COPY . .

# Create data directory for DuckDB governance (Railway volume mounts here)
RUN mkdir -p /app/data /app/logs /app/models/artifacts

# Expose port (Railway injects $PORT)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

# Start Plumber API
CMD Rscript -e "source('global_config.R'); pr <- plumber::plumb('api/plumber.R'); pr\$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT', '8080')))"