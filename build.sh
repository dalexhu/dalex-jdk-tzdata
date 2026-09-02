#!/usr/bin/env bash
#
# build.sh - build tz-patched Java images for a matrix of base images.
#
# Each build verifies itself: the Dockerfile runs the patched image and fails
# if the zone offset is wrong or zone ids were lost, so a broken image never
# gets tagged.
#
# Usage: ./build.sh [options] [base-image ...]
#        ./build.sh                       # the default matrix
#        ./build.sh amazoncorretto:21     # one specific base
#
# Portable: bash 3.2+, docker with BuildKit.

set -uo pipefail

VERSION="1.0.0"

TAG_PREFIX="${TAG_PREFIX:-dalex-jdk-tz}"
EXPECT_NOV="-06:00"
VERIFY_ZONE="America/Edmonton"
VERIFY_YEAR=2026
JDK_REF="master"
PUSH_PREFIX=""
PLATFORM=""
DRY_RUN=0

# The default matrix: the bases we actually deploy on.
DEFAULT_MATRIX="
eclipse-temurin:17-jre
eclipse-temurin:17-jdk
eclipse-temurin:21-jre
eclipse-temurin:21-jdk
eclipse-temurin:25-jre
eclipse-temurin:25-jdk
amazoncorretto:17
amazoncorretto:21
amazoncorretto:25
amazoncorretto:21-alpine
"

usage() {
  cat <<'USAGE'
build.sh - build tz-patched Java images

Usage: ./build.sh [options] [base-image ...]

Options:
  --zone <IANA>        Zone the build-time check uses (default America/Edmonton)
  --year <YYYY>        Year the build-time check uses (default 2026)
  --expect-nov <off>   Offset the patched image must produce on <year>-11-15
                       (default -06:00; pass "" to only check the tzdb version)
  --jdk-ref <ref>      OpenJDK git ref to take tzdata and tooling from
                       (default master - the newest tzdata OpenJDK has integrated;
                        pass a tag such as jdk-25+36 to pin it)
  --tag-prefix <name>  Image name prefix (default dalex-jdk-tz)
  --push <prefix>      After a successful build, tag and push as <prefix>/<image>:<tag>
  --platform <p>     Target platform, e.g. linux/amd64. The tzdb.dat build stage still
                     runs natively; only the patch and verify steps are emulated
  --dry-run            Print what would be built
  -h, --help           This help

Every base image listed on the command line replaces the default matrix.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --zone)        VERIFY_ZONE="$2"; shift ;;
    --year)        VERIFY_YEAR="$2"; shift ;;
    --expect-nov)  EXPECT_NOV="$2"; shift ;;
    --jdk-ref)     JDK_REF="$2"; shift ;;
    --tag-prefix)  TAG_PREFIX="$2"; shift ;;
    --push)        PUSH_PREFIX="$2"; shift ;;
    --platform)    PLATFORM="$2"; shift ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    --version)     echo "build.sh $VERSION"; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)             break ;;
  esac
  shift
done

MATRIX="$DEFAULT_MATRIX"
if [ $# -gt 0 ]; then
  MATRIX="$*"
fi

if [ -t 1 ]; then
  C_RESET='\033[0m'; C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_DIM='\033[2m'
else
  C_RESET=''; C_HEAD=''; C_OK=''; C_ERR=''; C_DIM=''
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS=""
FAILED=0

# tag name from a base image reference: eclipse-temurin:21-jre -> temurin-21-jre
tag_for() {
  echo "$1" | sed -e 's#^.*/##' -e 's#^eclipse-##' -e 's#^amazoncorretto#corretto#' -e 's#:#-#g'
}

for base in $MATRIX; do
  [ -n "$base" ] || continue
  tag="$TAG_PREFIX:$(tag_for "$base")"
  printf "\n${C_HEAD}==> %s  ->  %s${C_RESET}\n" "$base" "$tag"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry run)"
    continue
  fi

  # A base image that runs as a non-root user must end up as that user again;
  # read it from the image rather than making the caller remember.
  if ! docker pull -q ${PLATFORM:+--platform "$PLATFORM"} "$base" >/dev/null 2>&1; then
    printf "  ${C_ERR}pull failed${C_RESET}\n"
    RESULTS="$RESULTS
$base|-|PULL-FAILED"
    FAILED=$((FAILED + 1))
    continue
  fi
  final_user="$(docker inspect --format '{{.Config.User}}' "$base" 2>/dev/null)"
  [ -n "$final_user" ] || final_user="root"
  printf "  ${C_DIM}base user: %s${C_RESET}\n" "$final_user"

  if docker build -t "$tag" \
       ${PLATFORM:+--platform "$PLATFORM"} \
       --build-arg BASE_IMAGE="$base" \
       --build-arg BASE_IMAGE_LABEL="$base" \
       --build-arg FINAL_USER="$final_user" \
       --build-arg EXPECT_NOV="$EXPECT_NOV" \
       --build-arg VERIFY_ZONE="$VERIFY_ZONE" \
       --build-arg VERIFY_YEAR="$VERIFY_YEAR" \
       --build-arg JDK_REF="$JDK_REF" \
       "$HERE" > "/tmp/tzbuild.$$.log" 2>&1; then
    # the build already verified itself; run it once more as the final user
    out="$(docker run --rm "$tag" java -cp /opt/tzverify TzVerify "" "$VERIFY_ZONE" "$VERIFY_YEAR" "$EXPECT_NOV" 500 2>&1 | tail -2 | head -1)"
    printf "  ${C_OK}ok${C_RESET}  %s\n" "$out"
    RESULTS="$RESULTS
$base|$(echo "$out" | sed -n 's/.*tzdb=\([^ ]*\).*/\1/p')|OK"
    if [ -n "$PUSH_PREFIX" ]; then
      remote="$PUSH_PREFIX/$tag"          # keeps the repo:tag shape, e.g. host:5000/dalex-jdk-tz:temurin-21-jre
      docker tag "$tag" "$remote"
      if docker push "$remote" >/tmp/tzpush.$$.log 2>&1; then
        printf "  ${C_OK}pushed${C_RESET} %s\n" "$remote"
      else
        printf "  ${C_ERR}push failed${C_RESET}\n"
        tail -4 "/tmp/tzpush.$$.log" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
      fi
      rm -f "/tmp/tzpush.$$.log"
    fi
  else
    printf "  ${C_ERR}build failed${C_RESET}\n"
    tail -12 "/tmp/tzbuild.$$.log" | sed 's/^/    /'
    RESULTS="$RESULTS
$base|-|BUILD-FAILED"
    FAILED=$((FAILED + 1))
  fi
  rm -f "/tmp/tzbuild.$$.log"
done

printf "\n${C_HEAD}================ Summary ================${C_RESET}\n"
printf "  %-28s %-8s %s\n" "BASE IMAGE" "TZDB" "RESULT"
echo "$RESULTS" | grep -v '^$' | while IFS='|' read -r b v r; do
  case "$r" in
    OK) printf "  %-28s %-8s ${C_OK}%s${C_RESET}\n" "$b" "$v" "$r" ;;
    *)  printf "  %-28s %-8s ${C_ERR}%s${C_RESET}\n" "$b" "$v" "$r" ;;
  esac
done

exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
