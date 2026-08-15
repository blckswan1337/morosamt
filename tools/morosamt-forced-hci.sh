#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MOROSAMT ForcedUpgrade HCI capture
#
# Usage:
#   MOROSAMT_MODEL=v2-pro-lr bash morosamt-forced-hci.sh start
#   btfix
#   # reconnect XBOT and run the SAME current Forced Firmware upgrade once
#   bash morosamt-forced-hci.sh collect
#   bash morosamt-forced-hci.sh restore
#   btfix
#
# No firmware is modified by this script. It only controls Android HCI snooping.

MODE="${1:-status}"
MODEL_RAW="${MOROSAMT_MODEL:-v2-pro-lr}"

case "${MODEL_RAW,,}" in
    v2-pro-lr|v2prolr|pro-lr|prolr)
        MODEL_ID="v2-pro-lr"
        MODEL_NAME="E-Wheels E2S V2 Pro Long Range"
        CONTROLLER_SKU="9444"
        ;;
    v2-lr|v2lr|lr)
        MODEL_ID="v2-lr"
        MODEL_NAME="E-Wheels E2S V2 Long Range"
        CONTROLLER_SKU="9433"
        ;;
    *)
        echo "STOPP: ukjent MOROSAMT_MODEL='$MODEL_RAW'"
        exit 2
        ;;
esac

OUT="/sdcard/Download/MOROSAMT_FORCED_HCI"
STATE="$HOME/.morosamt-forced-hci.state"
LOGDIR="/data/misc/bluetooth/logs"
BASE="$LOGDIR/btsnoop_hci.log"

mkdir -p "$OUT"

root_getprop() {
    su -c "getprop '$1'" 2>/dev/null | tr -d '\r'
}

root_setting_get() {
    su -c "settings get global '$1'" 2>/dev/null | tr -d '\r'
}

case "$MODE" in
start)
    old_mode="$(root_getprop persist.bluetooth.btsnooplogmode)"
    old_default="$(root_getprop persist.bluetooth.btsnoopdefaultmode)"
    old_setting="$(root_setting_get bluetooth_btsnoop_log_mode)"

    {
        printf 'OLD_MODE=%q\n' "$old_mode"
        printf 'OLD_DEFAULT=%q\n' "$old_default"
        printf 'OLD_SETTING=%q\n' "$old_setting"
    } > "$STATE"

    echo "=== MOROSAMT FORCED UPDATE HCI: START ==="
    echo "Model=$MODEL_NAME"
    echo "Profile=$MODEL_ID controller_sku=$CONTROLLER_SKU"
    echo "Old persist.bluetooth.btsnooplogmode=${old_mode:-<empty>}"
    echo "Old persist.bluetooth.btsnoopdefaultmode=${old_default:-<empty>}"
    echo "Old global bluetooth_btsnoop_log_mode=${old_setting:-<empty>}"

    su -c 'setprop persist.bluetooth.btsnooplogmode full'
    su -c 'setprop persist.bluetooth.btsnoopdefaultmode full'
    su -c 'settings put global bluetooth_btsnoop_log_mode full' >/dev/null 2>&1 || true

    su -c "rm -f '$BASE' '$BASE.last' '$BASE.filtered' '$BASE.filtered.last'" \
        >/dev/null 2>&1 || true

    echo
    echo "Now:"
    echo "  persist.bluetooth.btsnooplogmode=$(root_getprop persist.bluetooth.btsnooplogmode)"
    echo "  persist.bluetooth.btsnoopdefaultmode=$(root_getprop persist.bluetooth.btsnoopdefaultmode)"
    echo
    echo "NEXT:"
    echo "  1) run: btfix"
    echo "  2) reconnect XBOT to the scooter"
    echo "  3) run the SAME MORO42001 current Forced Firmware upgrade ONCE"
    echo "  4) run: bash '$0' collect"
    ;;

collect)
    echo "=== MOROSAMT FORCED UPDATE HCI: COLLECT ==="
    rm -rf "$OUT"
    mkdir -p "$OUT"

    for f in \
        "$BASE" \
        "$BASE.last" \
        "$BASE.filtered" \
        "$BASE.filtered.last"
    do
        if su -c "test -f '$f'"; then
            name="$(basename "$f")"
            su -c "cp -f '$f' '/sdcard/Download/MOROSAMT_FORCED_HCI/$name'; chmod 0644 '/sdcard/Download/MOROSAMT_FORCED_HCI/$name'"
            echo "Copied: $f"
        fi
    done

    su -c 'logcat -b all -d -v threadtime "*:V"' 2>/dev/null \
        > "$OUT/logcat-all.txt" || true

    {
        echo "persist.bluetooth.btsnooplogmode=$(root_getprop persist.bluetooth.btsnooplogmode)"
        echo "persist.bluetooth.btsnoopdefaultmode=$(root_getprop persist.bluetooth.btsnoopdefaultmode)"
        echo "bluetooth_btsnoop_log_mode=$(root_setting_get bluetooth_btsnoop_log_mode)"
        echo "model_id=$MODEL_ID"
        echo "model_name=$MODEL_NAME"
        echo "controller_sku=$CONTROLLER_SKU"
        echo
        date
    } > "$OUT/state.txt"

    python - "$OUT" <<'PY'
from pathlib import Path
import struct, sys

root = Path(sys.argv[1])
lines = []

def parse(path):
    data = path.read_bytes()
    if len(data) < 16 or data[:8] != b"btsnoop\x00":
        return {"error": "not btsnoop", "size": len(data)}

    off = 16
    counts = {1:0, 2:0, 3:0, 4:0, 5:0, "other":0}
    recs = 0
    acl_samples = []

    while off + 24 <= len(data):
        orig, inc, flags, drops = struct.unpack(">IIII", data[off:off+16])
        ts = struct.unpack(">Q", data[off+16:off+24])[0]
        off += 24
        if off + inc > len(data):
            break

        pkt = data[off:off+inc]
        off += inc
        recs += 1

        if not pkt:
            counts["other"] += 1
            continue

        typ = pkt[0]
        if typ in counts:
            counts[typ] += 1
        else:
            counts["other"] += 1

        if typ == 2 and len(acl_samples) < 20:
            acl_samples.append(pkt[:64].hex().upper())

    return {
        "size": len(data),
        "records": recs,
        "command": counts[1],
        "acl": counts[2],
        "sco": counts[3],
        "event": counts[4],
        "iso": counts[5],
        "other": counts["other"],
        "acl_samples": acl_samples,
    }

for p in sorted(root.glob("btsnoop*")):
    r = parse(p)
    lines.append(f"FILE={p.name}")
    for k,v in r.items():
        if k != "acl_samples":
            lines.append(f"  {k}={v}")
    if r.get("acl_samples"):
        lines.append("  ACL_SAMPLES:")
        for x in r["acl_samples"]:
            lines.append("    " + x)
    lines.append("")

(root/"summary.txt").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY

    TGZ="/sdcard/Download/MOROSAMT_FORCED_HCI.tgz"
    rm -f "$TGZ"
    (
        cd /sdcard/Download
        tar -czf "$(basename "$TGZ")" MOROSAMT_FORCED_HCI
    )
    chmod 0644 "$TGZ" 2>/dev/null || true

    echo
    echo "Bundle: $TGZ"
    ls -lh "$TGZ"
    echo
    echo "If summary.txt shows acl=0, the vendor stack is still not exposing ACL"
    echo "to the filesystem snoop despite FULL mode. If acl>0, upload the TGZ."
    ;;

restore)
    echo "=== MOROSAMT FORCED UPDATE HCI: RESTORE ==="
    if [ -f "$STATE" ]; then
        . "$STATE"

        if [ -n "${OLD_MODE:-}" ]; then
            su -c "setprop persist.bluetooth.btsnooplogmode '$OLD_MODE'"
        else
            su -c 'setprop persist.bluetooth.btsnooplogmode ""'
        fi

        if [ -n "${OLD_DEFAULT:-}" ]; then
            su -c "setprop persist.bluetooth.btsnoopdefaultmode '$OLD_DEFAULT'"
        else
            su -c 'setprop persist.bluetooth.btsnoopdefaultmode ""'
        fi

        if [ "${OLD_SETTING:-}" = "null" ] || [ -z "${OLD_SETTING:-}" ]; then
            su -c 'settings delete global bluetooth_btsnoop_log_mode' >/dev/null 2>&1 || true
        else
            su -c "settings put global bluetooth_btsnoop_log_mode '$OLD_SETTING'" >/dev/null 2>&1 || true
        fi

        rm -f "$STATE"
    else
        echo "No saved state. Setting snoop mode to disabled."
        su -c 'setprop persist.bluetooth.btsnooplogmode disabled'
    fi

    echo "Restored property values."
    echo "Run btfix once so the Bluetooth stack reopens with the restored mode."
    ;;

status)
    echo "=== MOROSAMT FORCED UPDATE HCI: STATUS ==="
    echo "model=$MODEL_NAME"
    echo "profile=$MODEL_ID controller_sku=$CONTROLLER_SKU"
    echo "persist.bluetooth.btsnooplogmode=$(root_getprop persist.bluetooth.btsnooplogmode)"
    echo "persist.bluetooth.btsnoopdefaultmode=$(root_getprop persist.bluetooth.btsnoopdefaultmode)"
    echo "bluetooth_btsnoop_log_mode=$(root_setting_get bluetooth_btsnoop_log_mode)"
    echo
    su -c "ls -l '$LOGDIR'/btsnoop* 2>/dev/null || true"
    ;;

*)
    echo "Usage: $0 {start|collect|restore|status}"
    exit 2
    ;;
esac
