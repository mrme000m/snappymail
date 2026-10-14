#!/usr/bin/env bash
# Restart the preview-tunnel workflow with exactly one active run.
# Kills existing in_progress/queued runs on the branch (avoids duplicate
# tunnels), waits for cancellation, then dispatches a fresh run.
#
# Usage:
#   ./preview-tunnel.sh [--branch NAME] [--duration 180] [--port 8000]
#                       [--php 8.2] [--keep] [--yes] [--no-wait]
#
#   --keep    If a healthy run is already active, reuse it instead of restarting.
#   --yes     Skip the confirmation prompt (non-interactive / CI use).
#   --no-wait Don't wait for the new run's public URL; just dispatch and exit.
set -euo pipefail

WORKFLOW="preview-tunnel.yml"
BRANCH="$(git branch --show-current 2>/dev/null || echo master)"
DURATION="180"
PORT="8000"
PHP_VERSION="8.2"
# Never hardcode a password here (it would land in git). Pass via
# --admin-password, or export SNAPPYMAIL_ADMIN_PASSWORD. Empty = auto-generated.
ADMIN_PASSWORD="${SNAPPYMAIL_ADMIN_PASSWORD:-}"
PUBLIC_HOSTNAME="snap00.mrme.tech"
KEEP=0
YES=0
WAIT=1

usage() {
  cat <<'EOF'
Usage:
  ./preview-tunnel.sh [--branch NAME] [--duration 180] [--port 8000]
                      [--php 8.2] [--admin-password PASS] [--hostname HOST] [--keep] [--yes] [--no-wait]

  --admin-password PASS  Admin panel password (or set SNAPPYMAIL_ADMIN_PASSWORD; empty = auto-generated)
  --hostname HOST  Public hostname for named tunnel (default: snap00.mrme.tech)
  --keep    If a run is already active, reuse it instead of restarting.
  --yes     Skip the confirmation prompt (non-interactive / CI use).
  --no-wait Don't wait for the new run's public URL; just dispatch and exit.
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:?}"; shift 2 ;;
    --duration) DURATION="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --php) PHP_VERSION="${2:?}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:?}"; shift 2 ;;
    --hostname) PUBLIC_HOSTNAME="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --no-wait) WAIT=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need gh
need git
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated. Run: gh auth login" >&2; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repo: $REPO | branch: $BRANCH | workflow: $WORKFLOW"

active_runs() {
  gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=30" \
    --jq "[.workflow_runs[] | select(.head_branch==\"$BRANCH\" and (.status==\"in_progress\" or .status==\"queued\" or .status==\"waiting\" or .status==\"pending\")) | \"\(.id) \(.status) \(.created_at)\" ] | .[]"
}

echo "Checking for active runs..."
mapfile -t ACTIVE < <(active_runs || true)
if [ "${#ACTIVE[@]}" -gt 0 ] && [ -n "${ACTIVE[0]}" ]; then
  echo "Found ${#ACTIVE[@]} active run(s):"
  printf '  %s\n' "${ACTIVE[@]}"
  if [ "$KEEP" = "1" ]; then
    echo "Reusing existing run (--keep). Nothing to do."
    printf '  %s\n' "${ACTIVE[@]}" | awk '{print "  https://github.com/'"$REPO"'/actions/runs/" $1}'
    exit 0
  fi
  if [ "$YES" != "1" ]; then
    read -r -p "Cancel these and start a fresh run? [y/N] " ans
    case "$ans" in [yY][eE][sS]|[yY]) : ;; *) echo "Aborted."; exit 1 ;; esac
  fi
  for line in "${ACTIVE[@]}"; do
    id="${line%% *}"
    echo "Cancelling run $id..."
    gh run cancel "$id" >/dev/null 2>&1 || gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null || true
  done
  echo "Waiting for cancellations to settle..."
  for _ in $(seq 1 30); do
    sleep 5
    mapfile -t LEFT < <(active_runs || true)
    if [ "${#LEFT[@]}" -eq 0 ] || [ -z "${LEFT[0]}" ]; then echo "All old runs settled."; break; fi
    echo "  still active: ${#LEFT[@]}..."
    if [ "$_ " = "30 " ]; then echo "WARNING: some runs still active; continuing anyway."; fi
  done
else
  echo "No active runs — nothing to kill."
fi

echo "Dispatching fresh run (duration=${DURATION}m port=${PORT} php=${PHP_VERSION} hostname=${PUBLIC_HOSTNAME})..."
BEFORE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARGS=(-f duration_minutes="$DURATION" -f port="$PORT" -f php_version="$PHP_VERSION" -f public_hostname="$PUBLIC_HOSTNAME")
if [ -n "$ADMIN_PASSWORD" ]; then
  ARGS+=(-f admin_password="$ADMIN_PASSWORD")
fi
gh workflow run "$WORKFLOW" --ref "$BRANCH" "${ARGS[@]}"

if [ "$WAIT" = "0" ]; then
  echo "Dispatched (--no-wait). Track with: gh run list --workflow $WORKFLOW --branch $BRANCH"
  exit 0
fi

echo "Waiting for the new run to appear..."
NEW_ID=""
for _ in $(seq 1 24); do
  sleep 5
  NEW_ID="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=5" \
    --jq "[.workflow_runs[] | select(.head_branch==\"$BRANCH\" and .created_at>\"$BEFORE\")] | sort_by(.created_at) | last | .id // empty")"
  [ -n "$NEW_ID" ] && break
  echo "  ..."
done
[ -n "$NEW_ID" ] || { echo "New run did not appear; check: gh run list --workflow $WORKFLOW" >&2; exit 1; }
echo "New run: https://github.com/$REPO/actions/runs/$NEW_ID"

echo "Waiting for tunnel URL (up to ~6 min)..."
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
for _ in $(seq 1 36); do
  sleep 10
  URL_FILE="$(find "$TMPD" -name public-url.txt -size +0c 2>/dev/null | head -n1 || true)"
  if [ -n "${URL_FILE:-}" ]; then
    echo ""
    echo "Public URL: $(cat "$URL_FILE")"
    echo "Admin:      $(cat "$URL_FILE")/?admin"
    echo "Run page:   https://github.com/$REPO/actions/runs/$NEW_ID"
    exit 0
  fi
  # Re-download (artifact appears mid-run). rm first: old gh has no --clobber.
  find "$TMPD" -name public-url.txt -delete 2>/dev/null || true
  gh run download "$NEW_ID" -n tunnel-info -D "$TMPD" >/dev/null 2>&1 || true
  STATUS="$(gh run view "$NEW_ID" --json status,conclusion -q '"\(.status)/\(.conclusion)"' 2>/dev/null || echo "?")"
  echo "  [$(date -u +%H:%M:%SZ)] status=$STATUS, waiting for tunnel-info artifact..."
  case "$STATUS" in completed/*) echo "Run finished before URL appeared. See run page."; gh run view "$NEW_ID" --log-failed 2>/dev/null | tail -n 30; exit 1 ;; esac
done
echo "Timed out waiting for URL — check the run page." >&2
exit 1
