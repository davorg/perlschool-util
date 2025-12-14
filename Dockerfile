FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ------------------------------------------------------------
# OS packages: Perl, build deps, pandoc, wkhtmltopdf, Java, curl, unzip
# ------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      perl \
      cpanminus \
      make \
      gcc \
      libxml2-dev \
      libexpat1-dev \
      libssl-dev \
      zlib1g-dev \
      pandoc \
      wkhtmltopdf \
      default-jre-headless \
      curl \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Install epubcheck
# ------------------------------------------------------------
ENV EPUBCHECK_VERSION=5.3.0
RUN mkdir -p /opt && \
    curl -L \
      "https://github.com/w3c/epubcheck/releases/download/v${EPUBCHECK_VERSION}/epubcheck-${EPUBCHECK_VERSION}.zip" \
      -o /tmp/epubcheck.zip && \
    unzip /tmp/epubcheck.zip -d /opt && \
    mv /opt/epubcheck-${EPUBCHECK_VERSION} /opt/epubcheck && \
    rm /tmp/epubcheck.zip

ENV EPUBCHECK_JAR=/opt/epubcheck/epubcheck.jar

# ------------------------------------------------------------
# Copy perlschool-util repo into the image
# ------------------------------------------------------------
WORKDIR /opt/perlschool-util
COPY . /opt/perlschool-util

# ------------------------------------------------------------
# Install CPAN dependencies from cpanfile
# ------------------------------------------------------------
RUN cpanm --notest --quiet --installdeps . || \
    (cat /root/.cpanm/work/*/build.log 2>/dev/null || true; exit 1)

# ------------------------------------------------------------
# Make our tools easily accessible
# ------------------------------------------------------------
RUN ln -s /opt/perlschool-util/bin/make_book    /usr/local/bin/make_book && \
    ln -s /opt/perlschool-util/bin/check_ms_html /usr/local/bin/check_ms_html && \
    printf '#!/bin/sh\nexec java -jar "$EPUBCHECK_JAR" "$@"\n' \
      >/usr/local/bin/epubcheck && \
    chmod +x /usr/local/bin/epubcheck && \
    ln -s /usr/local/bin/epubcheck /usr/local/bin/epub_check

# Default working directory for book repos (overridable with -w)
WORKDIR /work

CMD ["/bin/bash"]

