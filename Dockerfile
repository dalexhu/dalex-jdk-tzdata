# Patches any Java image so its JDK carries an up-to-date tz database.
#
# Works two ways:
#   - as a replacement base image   (BASE_IMAGE=eclipse-temurin:21-jre)
#   - as a one-layer patch on an image you cannot rebuild
#     (BASE_IMAGE=example-app:1.2)
#
# The build ends with a non-zero status if the patched image does not produce the
# expected offset or loses zone ids, so no tag is produced in that case.
#
#   docker build -t myjdk:21-tz \
#     --build-arg BASE_IMAGE=eclipse-temurin:21-jre \
#     --build-arg EXPECT_NOV=-06:00 .

ARG BUILDER_IMAGE=eclipse-temurin:21-jdk
ARG BASE_IMAGE=eclipse-temurin:21-jre

# ---------------------------------------------------------------------------
# stage 1: compile tzdb.dat from OpenJDK's own tz database
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${BUILDER_IMAGE} AS builder

ARG JDK_REF=master
ARG GH=https://raw.githubusercontent.com/openjdk/jdk

WORKDIR /build

RUN set -eux; \
    mkdir -p src/build/tools/tzdb; \
    for f in TzdbZoneRulesCompiler.java TzdbZoneRulesProvider.java; do \
      curl -fsSL -o "src/build/tools/tzdb/$f" \
        "${GH}/${JDK_REF}/make/jdk/src/classes/build/tools/tzdb/$f"; \
    done; \
    for f in ZoneRules.java ZoneOffsetTransition.java ZoneOffsetTransitionRule.java Ser.java; do \
      curl -fsSL "${GH}/${JDK_REF}/src/java.base/share/classes/java/time/zone/$f" \
        | sed -e 's/package java.time.zone/package build.tools.tzdb/' \
        > "src/build/tools/tzdb/$f"; \
    done; \
    javac -nowarn -d classes $(find src -name '*.java')

RUN set -eux; \
    mkdir -p tzdata; \
    for f in VERSION africa antarctica asia australasia europe northamerica \
             southamerica backward etcetera gmt jdk11_backward; do \
      curl -fsSL -o "tzdata/$f" "${GH}/${JDK_REF}/src/java.base/share/data/tzdata/$f"; \
    done; \
    java -cp classes build.tools.tzdb.TzdbZoneRulesCompiler \
      -srcdir tzdata -dstfile /build/tzdb.dat \
      africa antarctica asia australasia europe northamerica southamerica \
      backward etcetera gmt jdk11_backward; \
    grep -o 'tzdata[0-9a-z]*' tzdata/VERSION | tail -1 | sed 's/^tzdata//' > /build/tzdata.version; \
    cat /build/tzdata.version

COPY TzVerify.java /build/TzVerify.java
RUN javac --release 8 -d /build/verify /build/TzVerify.java

# ---------------------------------------------------------------------------
# stage 2: drop it into the target image and prove the result
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

# Expectations the patched image must satisfy, checked at build time.
ARG EXPECT_TZDB=""
ARG EXPECT_NOV="-06:00"
ARG VERIFY_ZONE="America/Edmonton"
ARG VERIFY_YEAR=2026
# An image that runs as a non-root user needs this set back to that user,
# e.g. FINAL_USER=appuser. build.sh reads it from the base image with docker inspect.
ARG FINAL_USER=root
# only used to word the NOTICE file
ARG BASE_IMAGE_LABEL=""

USER root

COPY --from=builder /build/tzdb.dat      /tmp/tzdb.dat.new
COPY --from=builder /build/tzdata.version /tmp/tzdata.version
COPY --from=builder /build/verify/TzVerify.class /opt/tzverify/TzVerify.class

RUN set -eux; \
    java_bin="$(command -v java)"; \
    java_bin="$(readlink -f "$java_bin")"; \
    jh="$(dirname "$(dirname "$java_bin")")"; \
    if   [ -f "$jh/lib/tzdb.dat" ];     then target="$jh/lib/tzdb.dat"; \
    elif [ -f "$jh/jre/lib/tzdb.dat" ]; then target="$jh/jre/lib/tzdb.dat"; \
    else echo "no tzdb.dat under $jh - not a JDK 8+ image" >&2; exit 1; fi; \
    before="$(head -c 16 "$target" | tr -cd '0-9A-Za-z')"; \
    cp "$target" "$target.orig"; \
    cp /tmp/tzdb.dat.new "$target"; \
    chmod 644 "$target"; \
    after="$(head -c 16 "$target" | tr -cd '0-9A-Za-z')"; \
    echo "patched $target: ${before#TZDB} -> ${after#TZDB}  (original kept at $target.orig)"; \
    rm -f /tmp/tzdb.dat.new

# Fails the build - and therefore the tag - if the result is not what was asked for.
RUN set -eux; \
    want_db="${EXPECT_TZDB:-$(cat /tmp/tzdata.version)}"; \
    java -cp /opt/tzverify TzVerify "$want_db" "$VERIFY_ZONE" "$VERIFY_YEAR" "$EXPECT_NOV" 500

# Records in the image what it is and what was changed in it.
RUN set -eux; \
    ver="$(cat /tmp/tzdata.version)"; \
    { \
      echo "MODIFIED BUILD - NOT AN OFFICIAL VENDOR IMAGE"; \
      echo ""; \
      echo "This image is ${BASE_IMAGE_LABEL:-the stated base image} with exactly one change:"; \
      echo "the JDK time zone database at <java home>/lib/tzdb.dat was replaced with one"; \
      echo "compiled from OpenJDK's tz database at version tzdata${ver}."; \
      echo "The file it replaced is kept alongside it as tzdb.dat.orig."; \
      echo ""; \
      echo "No other file was added, removed or modified. The license and notice"; \
      echo "files of the base image are untouched."; \
      echo ""; \
      echo "The replacement was produced with OpenJDK's own build tool"; \
      echo "(build.tools.tzdb.TzdbZoneRulesCompiler, GPLv2 with Classpath Exception)"; \
      echo "from OpenJDK's tz database, which derives from the public-domain IANA tz database."; \
      echo ""; \
      echo "This build is not certified against the Java SE TCK, and no compatibility"; \
      echo "certification of the base image carries over to it. It is not endorsed by,"; \
      echo "affiliated with or supported by the vendor of the base image."; \
      echo ""; \
      echo "Base image sources: see the upstream project of the base image."; \
      echo "Recipe: https://github.com/dalexhu/dalex-jdk-tzdata"; \
    } > /NOTICE-tzdb.txt; \
    cat /NOTICE-tzdb.txt

LABEL org.opencontainers.image.description="Unofficial modified build: a Java base image whose JDK tz database (tzdb.dat) was replaced"
LABEL org.opencontainers.image.source="https://github.com/dalexhu/dalex-jdk-tzdata"
LABEL io.github.dalexhu.tzdb.patched="true"
LABEL io.github.dalexhu.tzdb.modification="jdk tzdb.dat replaced; original kept as tzdb.dat.orig"

USER ${FINAL_USER}
