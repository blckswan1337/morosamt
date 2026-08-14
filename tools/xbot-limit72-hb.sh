#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="com.mini.xbot"
SRC="${XBOT_LIMIT72_APK:-/sdcard/Download/XBOT_LIMIT72_HB_arm64.apk}"
TMP="/data/local/tmp/XBOT_LIMIT72_HB_arm64.apk"
ORIG_SHA="1fe680898f86018c272775148b3a19267ef2371fb170691c38d5201e35bd3de5"
PATCH_SHA="a1ec34aacdfee31330a70807b5bff8784003a8bdecdabd10cf84e29bd1a04fa1"

find_target() {
  su -c "pm path '$PKG' 2>/dev/null" 2>/dev/null |
    sed 's/^package://' |
    grep -E 'split_config\.arm64_v8a\.apk$|arm64.*\.apk$' |
    head -n1
}

TARGET="$(find_target || true)"
[ -n "$TARGET" ] || {
  TARGET="$(su -c "find /data/app -type f -name 'split_config.arm64_v8a.apk' -path '*com.mini.xbot*' 2>/dev/null | head -n1" 2>/dev/null || true)"
}
[ -n "$TARGET" ] || { echo "STOPP: fant ikke XBOT ARM64-split"; exit 1; }

MODE="${1:-install}"

unmount_overlay() {
  su -mm -c "umount '$TARGET' 2>/dev/null || true" >/dev/null 2>&1 || true
  su -c "umount '$TARGET' 2>/dev/null || true" >/dev/null 2>&1 || true
}

case "$MODE" in
  restore)
    su -c "am force-stop '$PKG'" >/dev/null 2>&1 || true
    unmount_overlay
    su -c "rm -f '$TMP'" >/dev/null 2>&1 || true
    echo "RESTORED"
    su -c "sha256sum '$TARGET'" || true
    exit 0
    ;;
  status)
    echo "Target: $TARGET"
    su -c "sha256sum '$TARGET'" || true
    su -c "grep -F ' $TARGET ' /proc/mounts || true" || true
    exit 0
    ;;
  capture)
    OUT="/sdcard/Download/XBOT_LIMIT72_HCI.cfa"
    LATEST="$(su -c "find /data/misc/bluetooth/logs -maxdepth 1 -type f \( -name 'BT_HCI*' -o -name '*btsnoop*' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-" 2>/dev/null || true)"
    [ -n "$LATEST" ] || { echo "Fant ingen HCI-logg"; exit 1; }
    su -c "cp '$LATEST' '$OUT'; chmod 0644 '$OUT'"
    echo "COPIED: $OUT"
    ls -lh "$OUT"
    exit 0
    ;;
  install) ;;
  *) echo "Usage: $0 [install|status|capture|restore]"; exit 2 ;;
esac

[ -f "$SRC" ] || { echo "STOPP: mangler $SRC"; exit 1; }
ACTUAL="$(sha256sum "$SRC" | awk '{print $1}')"
[ "$ACTUAL" = "$PATCH_SHA" ] || {
  echo "STOPP: feil patch SHA"
  echo "got : $ACTUAL"
  echo "want: $PATCH_SHA"
  exit 1
}

echo "=== XBOT LIMIT 0x72 -> HB TEST ==="
echo "Target split: $TARGET"
echo "Original SHA: $ORIG_SHA"
echo "Patched SHA : $PATCH_SHA"
echo

su -c "am force-stop '$PKG'" >/dev/null 2>&1 || true

# Remove the old PoJie/other bind overlay first.
unmount_overlay

UNDER="$(su -c "sha256sum '$TARGET' | awk '{print \$1}'")"
echo "Underlying SHA: $UNDER"
[ "$UNDER" = "$ORIG_SHA" ] || {
  echo "STOPP: installed XBOT split is not the exact analyzed build."
  exit 1
}

su -c "cp -f '$SRC' '$TMP'; chmod 0644 '$TMP'"
CTX="$(su -c "ls -Zd '$TARGET' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
[ -z "$CTX" ] || su -c "chcon '$CTX' '$TMP' 2>/dev/null || true"

if su -mm -c "mount --bind '$TMP' '$TARGET'"; then
  :
elif su -c "mount --bind '$TMP' '$TARGET'"; then
  echo "[!] su -mm unavailable; used current root namespace."
else
  echo "STOPP: bind mount failed"
  exit 1
fi

VISIBLE="$(su -c "sha256sum '$TARGET' | awk '{print \$1}'")"
[ "$VISIBLE" = "$PATCH_SHA" ] || {
  echo "STOPP: patched split is not visible"
  exit 1
}

echo
echo "PATCH ACTIVE."
echo "Only native change:"
echo "  XBOT onClickLimit(): register 0x72 now uses HB address 0x20."
echo
echo "Captured controller state before this experiment:"
echo "  reg 0x1D = 0x07F9, bit0=1"
echo "Therefore the FIRST limiter toggle requests LIMIT OFF (0x72=0)."
echo
echo "1) Open XBOT and connect."
echo "2) Tap the speed-limit / T_Limit control ONCE."
echo "3) Wait ~5 seconds."
echo "4) Run:"
echo "   bash '$HOME/xbot-limit72-hb.sh' capture"
echo
echo "Keep scooter stationary/off the ground during the write."
echo
echo "Restore:"
echo "   bash '$HOME/xbot-limit72-hb.sh' restore"
