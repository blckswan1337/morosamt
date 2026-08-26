#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MOROSAMT ONE
# Minimal frontend: run | status | restore
# Default = run

HERE="$(cd "$(dirname "$0")" && pwd)"
AUTO="$HERE/morosamt-auto.sh"
FORCED="$HERE/morosamt-forced-dk-local.sh"
HCI="$HERE/morosamt-forced-hci.sh"
MODE="${1:-run}"

say(){ printf '%s\n' "$*"; }
stop(){ say "STOPP: $*"; exit 1; }

[ -f "$AUTO" ] || stop "mangler $AUTO"
[ -f "$FORCED" ] || stop "mangler $FORCED"
[ -f "$HCI" ] || stop "mangler $HCI"

case "$MODE" in
  run)
    say "=== MOROSAMT ONE ==="
    say "Parser lokal state og velger tryggeste automatiserbare løp."
    say

    # First let the richer parser build/update state and confidence.
    bash "$AUTO" auto

    # If a verified current profile is now available, arm HCI capture too.
    # The existing tools retain their own model/hash guards.
    if [ -f "$HOME/.morosamt-auto.env" ]; then
      # shellcheck disable=SC1090
      . "$HOME/.morosamt-auto.env" || true
    fi

    profile="${MOROSAMT_MODEL:-${MODEL_ID:-}}"
    confidence="${CONFIDENCE:-0}"

    case "$confidence" in
      ''|*[!0-9]*) confidence=0 ;;
    esac

    if [ "$profile" = "v2-pro-lr" ] && [ "$confidence" -ge 90 ]; then
      say
      say "Verified profile detected: v2-pro-lr ($confidence%)"
      say "Enabling HCI capture for the next manual XBOT update cycle."
      MOROSAMT_MODEL=v2-pro-lr bash "$HCI" start || true
      say
      say "READY: open XBOT and run Forced Firmware upgrade with MORO42001 once."
      say "Afterwards run: bash '$0' status"
    else
      say
      say "No high-confidence current-flash profile yet."
      say "Tool has stopped at probe/discovery state."
    fi
    ;;

  status)
    say "=== MOROSAMT ONE STATUS ==="
    bash "$AUTO" status 2>/dev/null || true
    say
    bash "$FORCED" status 2>/dev/null || true
    say
    bash "$HCI" status 2>/dev/null || true
    say
    if [ -f /sdcard/Download/MOROSAMT_FORCED_HTTP.log ]; then
      say "=== HTTP TAIL ==="
      tail -n 20 /sdcard/Download/MOROSAMT_FORCED_HTTP.log || true
    fi
    say
    if [ -d /sdcard/Download/MOROSAMT_FORCED_HCI ]; then
      say "=== HCI OUTPUT ==="
      ls -lh /sdcard/Download/MOROSAMT_FORCED_HCI 2>/dev/null || true
    fi
    ;;

  restore)
    say "=== MOROSAMT ONE RESTORE ==="
    bash "$FORCED" restore 2>/dev/null || true
    bash "$HCI" restore 2>/dev/null || true
    rm -f "$HOME/.morosamt-auto.env" 2>/dev/null || true
    say "Restored."
    ;;

  *)
    say "Usage: $0 [run|status|restore]"
    exit 2
    ;;
esac
