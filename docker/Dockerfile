# KH Coder, serverless (SQLite) and slimmed.
#
# Two stages: the builder holds the toolchain needed to fetch CPAN and CRAN
# packages, the runtime holds none of it. Nothing here is compiled from source
# -- the CPAN modules are pure Perl and the CRAN packages arrive as binaries --
# so the toolchain never reaches the final image.

# ------------------------------------------------------------------- base ---
# Both stages share this, so the builder resolves and load-checks packages
# against exactly the libraries the runtime will have.
FROM debian:bookworm AS base

ENV DEBIAN_FRONTEND=noninteractive LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8

# mecab Depends on "mecab-jumandic | mecab-ipadic" and apt takes the first
# alternative even when ipadic is requested in the same transaction, dragging in
# a 206MB dictionary nothing reads. Purging it in this same layer is what
# actually removes it; ipadic then satisfies the alternative on its own.
RUN apt-get update && apt-get install -y --no-install-recommends \
      perl libtk-perl \
      mecab mecab-ipadic-utf8 \
      sqlite3 libdbi-perl libdbd-sqlite3-perl libdbd-csv-perl \
      libjcode-perl libfile-bom-perl libtext-csv-xs-perl \
      libspreadsheet-parseexcel-perl libspreadsheet-parsexlsx-perl \
      libexcel-writer-xlsx-perl libclone-perl libtext-diff-perl \
      libyaml-perl libnet-telnet-perl libstatistics-descriptive-perl \
      libunicode-string-perl liblingua-en-tagger-perl \
      libalgorithm-naivebayes-perl libthread-queue-any-perl \
      libfile-copy-recursive-perl \
      liblingua-stem-snowball-perl libtext-unidecode-perl liblingua-sentence-perl \
      libimage-magick-perl libclipboard-perl libnkf-perl \
      r-base-core r-recommended \
      r-cran-ggplot2 r-cran-rcolorbrewer r-cran-gtable r-cran-gridextra \
      r-cran-cowplot r-cran-ggsci r-cran-ggdendro r-cran-colorspace \
      r-cran-igraph r-cran-network r-cran-proxy r-cran-amap \
      r-cran-wordcloud r-cran-scatterplot3d r-cran-pheatmap r-cran-maptools \
      r-cran-cairo \
      libgsl27 libgslcblas0 libxft2 libx11-6 libfontconfig1 \
      libicu72 libgomp1 libgmp10 libmpfr6 \
      fonts-ipafont-gothic \
      locales x11-apps xauth procps \
 && apt-get purge -y mecab-jumandic-utf8 mecab-jumandic \
 && sed -i 's/^# *\(ja_JP.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------- builder ---
FROM base AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      cpanminus make ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pure-Perl modules with no Debian package.
RUN cpanm --notest \
      Statistics::Lite \
      Statistics::R \
      Statistics::ChisqIndep \
      Unicode::Escape \
      Lingua::JA::Regular::Unicode \
      Tk::MatchEntry \
 || (cat /root/.cpanm/work/*/build.log | tail -60; exit 1)

# CRAN packages with no Debian package, from a pinned Posit snapshot that still
# targets R 4.2 (bookworm's R). The __linux__/bookworm path plus the
# HTTPUserAgent option serves precompiled binaries, so nothing is built here.
#
# Deliberately absent:
#   smacof         - one of three MDS methods, but pulls 107 packages (187MB);
#                    Classical and Kruskal remain. Removed from the UI menu too.
#   RSVGTipsDevice - unavailable for R 4.2, and kh_r_plot.pm only reaches it on
#                    darwin; Linux takes the Cairo svg() branch.
#   vegan          - only referenced by the optional plugin_jp/plugin_en scripts.
RUN Rscript -e 'options(HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(), \
      paste(getRversion(), R.version$platform, R.version$arch, R.version$os))); \
      pk <- c("som","topicmodels","ggnetwork","ldatuning","networkD3","devEMF"); \
      install.packages(pk, \
        repos="https://packagemanager.posit.co/cran/__linux__/bookworm/2023-04-20", \
        Ncpus=parallel::detectCores()); \
      m <- pk[!sapply(pk, requireNamespace, quietly=TRUE)]; \
      if (length(m)) stop("R packages failed to install: ", paste(m, collapse=", "))' \
 && rm -rf /usr/local/lib/R/site-library/BH \
           /usr/local/lib/R/site-library/RcppEigen


# ---------------------------------------------------------------- runtime ---
FROM base

COPY --from=builder /usr/local/share/perl         /usr/local/share/perl
COPY --from=builder /usr/local/lib/R/site-library /usr/local/lib/R/site-library

WORKDIR /khcoder/src
CMD ["/bin/bash"]
