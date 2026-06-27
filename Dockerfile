# Healthcare Readmission Pipeline — Railway Deployment
# Uses Posit Package Manager for fast binary R package installs
FROM rocker/r-ver:4.4.2

# System libraries needed by R packages
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
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
    libgit2-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Configure R to use Posit Package Manager binaries (much faster than source)
RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/latest"))' >> /usr/local/lib/R/etc/Rprofile.site

# Install renv first
RUN R -e "install.packages('renv')"

# Copy renv lock files for cache layer
COPY renv.lock renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/.gitignore renv/.gitignore
COPY renv/settings.json renv/settings.json
COPY .Rprofile .Rprofile

# Restore packages (binary installs from Posit PM — much faster)
RUN R -e "renv::restore(prompt = FALSE)"

# Copy project files
COPY . .

# Create required directories
RUN mkdir -p /app/data /app/logs

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

CMD Rscript -e "source('global_config.R'); pr <- plumber::plumb('api/plumber.R'); pr\$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT', '8080')))"