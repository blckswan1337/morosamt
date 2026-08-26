#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MOROSAMT AUTO
# Thin orchestration layer over the verified repo tools.
# It automates only decisions that can be justified by parsable local state.

HERE="$(cd "$(dirname "$0")" && pwd)"
FORCED="$HERE/morosamt-forced-dk-local.sh"
HCI="$HERE/morosamt-forced-hci.sh"
STATE="$HOME/.morosamt-auto.env"
REPORT="/sdcard/Download/MOROSAMT_AUTO_REPORT.txt"
CODE="${MOROSAMT_CODE:-MORO42001}"
DK_SHA_PRO="856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62"
DK_SIZE_PRO=28444

say(){ printf '%s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
need(){ have "$1" || { say "STOPP: mangler $1"; exit 1; }; }

root_ok(){ su -c id 2>/dev/null | grep -q 'uid=0'; }

find_xbot_split(){
  su -c "pm path com.mini.xbot 2>/dev/null" 2>/dev/null |
    sed 's/^package://' |
    grep -E 'split_config\.arm64_v8a\.apk$|arm64.*\.apk$' |
    head -n1 || true
}

find_dk_candidates(){
  find /sdcard/Download /sdcard/Documents "$HOME" -maxdepth 4 -type f \
    \( -iname 'DK*.bin' -o -iname '*061007f9*.bin' \) 2>/dev/null | sort -u
}

identify_profile(){
  # Strongest evidence first: exact verified current DK hash/size.
  local f sha sz
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sha="$(sha256sum "$f" | awk '{print $1}')"
    sz="$(wc -c < "$f" | tr -d ' ')"
    if [ "$sha" = "$DK_SHA_PRO" ] && [ "$sz" = "$DK_SIZE_PRO" ]; then
      printf 'v2-pro-lr|dk_hash|100|%s\n' "$f"
      return 0
    fi
  done < <(find_dk_candidates)

  # Parse explicit previous MOROSAMT state/log evidence.
  for f in "$STATE" /sdcard/Download/MOROSAMT_FORCED_HCI/state.txt "$REPORT"; do
    [ -f "$f" ] || continue
    if grep -Eqi 'model(_id)?[=: ]+v2-pro-lr|controller(_sku)?[=: ]+9444|DK[_ ]?MODEL[=: ]+0x?84a8|DK[_ ]?ID[=: ]+0x?061007f9' "$f"; then
      printf 'v2-pro-lr|state_parse|90|%s\n' "$f"
      return 0
    fi
    if grep -Eqi 'model(_id)?[=: ]+v2-lr|controller(_sku)?[=: ]+9433' "$f"; then
      printf 'v2-lr|state_parse|80|%s\n' "$f"
      return 0
    fi
  done

  # Environment is explicit operator intent, but not hardware proof.
  case "${MOROSAMT_MODEL:-}" in
    v2-pro-lr|v2prolr|pro-lr|prolr) printf 'v2-pro-lr|env|70|MOROSAMT_MODEL\n'; return 0;;
    v2-lr|v2lr|lr) printf 'v2-lr|env|70|MOROSAMT_MODEL\n'; return 0;;
  esac

  printf 'unknown|none|0|none\n'
}

save_state(){
  cat > "$STATE" <<EOF
MOROSAMT_MODEL='$MODEL'
MOROSAMT_CONFIDENCE='$CONF'
MOROSAMT_EVIDENCE='$EVIDENCE'
MOROSAMT_SOURCE='$SOURCE'
MOROSAMT_CODE='$CODE'
EOF
}

parse_identity(){
  IFS='|' read -r MODEL EVIDENCE CONF SOURCE < <(identify_profile)
  export MOROSAMT_MODEL="$MODEL"
  export MOROSAMT_CODE="$CODE"
  save_state
}

report(){
  parse_identity
  local split splitsha="missing" patch="missing" server="missing" dk="none"
  split="$(find_xbot_split)"
  [ -z "$split" ] || splitsha="$(su -c "sha256sum '$split' 2>/dev/null" 2>/dev/null | awk '{print $1}')"
  [ -f "$HERE/payload/XBOT_FORCED_LOCAL_arm64.apk" ] && patch="present"
  [ -f "$HERE/forced_server.py" ] && server="present"
  if [ "$MODEL" = v2-pro-lr ]; then
    dk="$(find_dk_candidates | while read -r f; do [ "$(sha256sum "$f"|awk '{print $1}')" = "$DK_SHA_PRO" ] && { echo "$f"; break; }; done)"
    [ -n "$dk" ] || dk="missing"
  fi
  {
    echo '=== MOROSAMT AUTO REPORT ==='
    date
    echo "model=$MODEL"
    echo "confidence=$CONF"
    echo "evidence=$EVIDENCE"
    echo "source=$SOURCE"
    echo "code=$CODE"
    echo "root=$(root_ok && echo yes || echo no)"
    echo "xbot_split=${split:-missing}"
    echo "xbot_sha=$splitsha"
    echo "patched_payload=$patch"
    echo "forced_server=$server"
    echo "verified_current_dk=$dk"
    echo "forced_harness=$([ -f "$FORCED" ] && echo present || echo missing)"
    echo "hci_harness=$([ -f "$HCI" ] && echo present || echo missing)"
  } | tee "$REPORT"
}

require_profile(){
  parse_identity
  [ "$MODEL" != unknown ] || {
    say 'STOPP: kan ikke identifisere profil fra parsbar evidens.'
    say 'Kjør doctor, eller sett MOROSAMT_MODEL eksplisitt for probe/capture.'
    exit 10
  }
}

require_current_safe(){
  require_profile
  [ "$MODEL" = v2-pro-lr ] || { say "STOPP: current er ikke verifisert for $MODEL"; exit 12; }
  [ "$CONF" -ge 90 ] || {
    say "STOPP: current krever >=90% parser-confidence; har $CONF% ($EVIDENCE)."
    say "Legg den verifiserte current DK-filen i Download, eller bruk probe først."
    exit 13
  }
}

stage_verified_dk(){
  local src=""
  src="$(find_dk_candidates | while read -r f; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$DK_SHA_PRO" ] || continue
    [ "$(wc -c < "$f" | tr -d ' ')" = "$DK_SIZE_PRO" ] || continue
    echo "$f"; break
  done)"
  [ -n "$src" ] || { say 'STOPP: finner ikke verifisert DK061007f9.bin'; exit 14; }

  local root="$HERE/server/f/$CODE"
  mkdir -p "$root"
  cp -f "$src" "$root/DK.bin"
  cp -f "$src" "$root/DK01.bin"
  say "DK staged: $src -> $root/{DK.bin,DK01.bin}"
}

cmd_doctor(){
  need sha256sum
  report
  echo
  root_ok || say '[!] root mangler/feiler'
  [ -n "$(find_xbot_split)" ] || say '[!] XBOT ARM64 split ikke funnet'
  [ -f "$HERE/forced_server.py" ] || say '[!] forced_server.py mangler i repo/worktree'
  [ -f "$HERE/payload/XBOT_FORCED_LOCAL_arm64.apk" ] || say '[!] patched XBOT payload mangler i repo/worktree'
  say "Report: $REPORT"
}

cmd_probe(){
  require_profile
  [ -f "$FORCED" ] || { say "STOPP: mangler $FORCED"; exit 1; }
  say "AUTO: profile=$MODEL confidence=$CONF% via $EVIDENCE"
  MOROSAMT_MODEL="$MODEL" MOROSAMT_CODE="$CODE" bash "$FORCED" probe
}

cmd_current(){
  require_current_safe
  stage_verified_dk
  [ -f "$FORCED" ] || exit 1
  say "AUTO: armer kun verifisert current DK for $MODEL"
  MOROSAMT_MODEL="$MODEL" MOROSAMT_CODE="$CODE" bash "$FORCED" current
}

cmd_capture_start(){
  require_profile
  [ -f "$HCI" ] || { say "STOPP: mangler $HCI"; exit 1; }
  MOROSAMT_MODEL="$MODEL" bash "$HCI" start
}

cmd_capture_collect(){
  require_profile
  MOROSAMT_MODEL="$MODEL" bash "$HCI" collect
  if [ -f /sdcard/Download/MOROSAMT_FORCED_HCI/summary.txt ]; then
    echo
    grep -E '^(FILE=|  acl=|  records=)' /sdcard/Download/MOROSAMT_FORCED_HCI/summary.txt || true
  fi
}

cmd_status(){
  report
  if [ -f "$FORCED" ] && [ "$MODEL" != unknown ]; then
    echo
    MOROSAMT_MODEL="$MODEL" MOROSAMT_CODE="$CODE" bash "$FORCED" status || true
  fi
}

cmd_restore(){
  parse_identity
  if [ -f "$FORCED" ] && [ "$MODEL" != unknown ]; then
    MOROSAMT_MODEL="$MODEL" bash "$FORCED" restore || true
  fi
  if [ -f "$HCI" ] && [ "$MODEL" != unknown ]; then
    MOROSAMT_MODEL="$MODEL" bash "$HCI" restore || true
  fi
}

cmd_auto(){
  cmd_doctor
  parse_identity
  echo
  if [ "$MODEL" = unknown ]; then
    say 'AUTO RESULT: ukjent profil -> stopper ved discovery.'
    exit 10
  fi
  say "AUTO RESULT: $MODEL confidence=$CONF% evidence=$EVIDENCE"
  if [ "$MODEL" = v2-pro-lr ] && [ "$CONF" -ge 90 ]; then
    say 'Neste sikre automatiserbare trinn: current kan stages, men startes ikke automatisk.'
    say "Kjør: bash '$0' current"
  else
    say 'Neste sikre automatiserbare trinn: probe/capture.'
    say "Kjør: bash '$0' probe"
  fi
}

case "${1:-auto}" in
  auto) cmd_auto ;;
  doctor) cmd_doctor ;;
  probe) cmd_probe ;;
  current) cmd_current ;;
  capture-start) cmd_capture_start ;;
  capture-collect) cmd_capture_collect ;;
  status) cmd_status ;;
  restore) cmd_restore ;;
  *)
    cat <<EOF
Usage: $0 {auto|doctor|probe|current|capture-start|capture-collect|status|restore}

Environment:
  MOROSAMT_MODEL=v2-pro-lr|v2-lr
  MOROSAMT_CODE=MORO42001

Rules:
  - parser evidence outranks marketing names
  - current is blocked unless exact verified DK hash/size or equivalent >=90% evidence exists
  - XBOT update button is never pressed automatically
EOF
    exit 2
    ;;
esac
