#!/usr/bin/env bash
set -euo pipefail

# Rebuild / incrementally update the semantic search index for Gramps Web.
# Usage:
#   ./index-semantic.sh                 # incremental update
#   ./index-semantic.sh --full          # full reindex
#   ./index-semantic.sh --tree <ID>     # index a specific tree (default: first tree)

cd "$(dirname "$0")"

MODE="index-incremental"
TREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) MODE="index-full"; shift ;;
    --tree) TREE="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

# Prevent concurrent runs (sqlite refuses a second writer).
LOCK="/tmp/grampsweb_index.lock"
if ! docker compose exec -T grampsweb_celery sh -c \
    "mkdir $LOCK 2>/dev/null"; then
  echo "ERROR: another index run is in progress; aborting." >&2
  exit 1
fi
trap 'docker compose exec -T grampsweb_celery sh -c "rmdir $LOCK" 2>/dev/null || true' EXIT

# Secret is only mounted in the web container; reuse it for the CLI.
SECRET_KEY=$(docker compose exec -T grampsweb sh -c 'cat /app/secret/secret' 2>/dev/null || true)
if [[ -z "$SECRET_KEY" ]]; then
  echo "ERROR: could not read SECRET_KEY from the web container" >&2
  exit 1
fi

if [[ -z "$TREE" ]]; then
  TREE=$(docker compose exec -T grampsweb_celery sh -c \
    'ls /root/.gramps/grampsdb/ 2>/dev/null | head -1' || true)
fi
if [[ -z "$TREE" ]]; then
  echo "ERROR: no tree found. Pass one explicitly with --tree <ID>." >&2
  exit 1
fi

echo "== Tree: $TREE"
echo "== Mode: $MODE (semantic)"

T0=$(date +%s)
if docker compose exec -T grampsweb_celery sh -c \
    "export GRAMPSWEB_SECRET_KEY=$SECRET_KEY && \
     python3 -m gramps_webapi --config /dev/null \
       search --tree $TREE --semantic $MODE"; then
  echo "== Done in $(( $(date +%s) - T0 ))s"
else
  echo "== Indexing failed (see errors above)" >&2
  exit 1
fi