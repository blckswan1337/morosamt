#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MOROSAMT local ForcedUpgrade harness
# Commands:
#   profiles      show supported scooter/controller profiles
#   install       bind-mount patched XBOT ARM64 split
#   probe         install patch + serve Config.xml only (NO binary / NO flash)
#   current       install patch + serve verified current DK image
#   log           show HTTP request log
#   status        patch/server status
#   stop          stop local HTTP server
#   restore       stop server + remove XBOT bind overlay
#
# Model selection:
#   MOROSAMT_MODEL=v2-pro-lr   verified live profile in this research
#   MOROSAMT_MODEL=v2-lr       routing/capture only until live DK is recovered
#
# The script never presses the XBOT update button for you.
# "current" only ARMS a verified current vendor DK. Flash still requires your
# manual action inside XBOT.

PKG="com.mini.xbot"
CODE="${MOROSAMT_CODE:-MORO42001}"
PORT="${MOROSAMT_PORT:-8765}"

# Marketing model is metadata + compatibility guard. Do not infer firmware
# identity merely from the scooter name: E-Wheels uses separate controller
# variants for V2 LR and V2 Pro LR, and supplier revisions can vary.
MODEL_RAW="${MOROSAMT_MODEL:-v2-pro-lr}"

case "${MODEL_RAW,,}" in
    v2-pro-lr|v2prolr|pro-lr|prolr)
        MODEL_ID="v2-pro-lr"
        MODEL_NAME="E-Wheels E2S V2 Pro Long Range"
        CONTROLLER_SKU="9444"
        VERIFIED_CURRENT=1

        # Verified from the live target used by this research.
        TARGET_DK_ID="061007f9"
        TARGET_DK_MODEL="84a8"
        TARGET_DK_VERSION_DEC="33960"
        ;;

    v2-lr|v2lr|lr)
        MODEL_ID="v2-lr"
        MODEL_NAME="E-Wheels E2S V2 Long Range"
        CONTROLLER_SKU="9433"
        VERIFIED_CURRENT=0

        # The original V2 LR controller identity has not been verified in this
        # project. Probe/capture mode is allowed, but current-image flashing is
        # deliberately blocked until a live DK identity/image is recovered.
        TARGET_DK_ID="UNKNOWN"
        TARGET_DK_MODEL="UNKNOWN"
        TARGET_DK_VERSION_DEC="UNKNOWN"
        ;;

    *)
        echo "STOPP: ukjent MOROSAMT_MODEL='$MODEL_RAW'"
        echo "Gyldige profiler:"
        echo "  v2-pro-lr   E2S V2 Pro Long Range"
        echo "  v2-lr       E2S V2 Long Range"
        exit 2
        ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/payload/XBOT_FORCED_LOCAL_arm64.apk"
SERVER="$HERE/forced_server.py"
ROOT="$HERE/server"

TMPAPK="/data/local/tmp/XBOT_FORCED_LOCAL_arm64.apk"
PIDFILE="$HOME/.morosamt-forced-dk.pid"
HTTPLOG="/sdcard/Download/MOROSAMT_FORCED_HTTP.log"

ORIG_SHA="1fe680898f86018c272775148b3a19267ef2371fb170691c38d5201e35bd3de5"
PATCH_SHA="364e97b8b7a8ce3d8da98e99a46e6d61677a3edd28d18a1b628b2f237be80b20"
DK_SHA="856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62"
DK_SIZE="28444"

cmd="${1:-status}"

print_profile() {
    echo "=== MOROSAMT TARGET PROFILE ==="
    echo "Model:          $MODEL_NAME"
    echo "Profile:        $MODEL_ID"
    echo "Controller SKU: $CONTROLLER_SKU"
    echo "Forced code:    $CODE"
    echo "DK ID:          $TARGET_DK_ID"
    echo "DK model:       $TARGET_DK_MODEL"
    echo "DK version:     $TARGET_DK_VERSION_DEC"
    if [ "$VERIFIED_CURRENT" = "1" ]; then
        echo "Current DK:     VERIFIED for this live profile"
    else
        echo "Current DK:     NOT VERIFIED for this profile"
    fi
}

find_target() {
    local t=""
    t="$(su -c "pm path '$PKG' 2>/dev/null" 2>/dev/null |
        sed 's/^package://' |
        grep -E 'split_config\.arm64_v8a\.apk$|arm64.*\.apk$' |
        head -n1 || true)"

    if [ -z "$t" ]; then
        t="$(su -c "find /data/app -type f -name 'split_config.arm64_v8a.apk' -path '*com.mini.xbot*' 2>/dev/null | head -n1" 2>/dev/null || true)"
    fi

    printf '%s' "$t"
}

TARGET="$(find_target)"
[ -n "$TARGET" ] || {
    echo "STOPP: fant ikke installert XBOT ARM64-split."
    exit 1
}

stop_server() {
    if [ -f "$PIDFILE" ]; then
        p="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            kill "$p" 2>/dev/null || true
            for _ in 1 2 3 4 5; do
                kill -0 "$p" 2>/dev/null || break
                sleep 0.15
            done
            kill -9 "$p" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
}

unmount_patch() {
    su -c "am force-stop '$PKG'" >/dev/null 2>&1 || true
    su -mm -c "umount '$TARGET' 2>/dev/null || true" >/dev/null 2>&1 || true
    su -c "umount '$TARGET' 2>/dev/null || true" >/dev/null 2>&1 || true
}

install_patch() {
    [ -f "$PATCH" ] || { echo "STOPP: mangler $PATCH"; exit 1; }

    got="$(sha256sum "$PATCH" | awk '{print $1}')"
    [ "$got" = "$PATCH_SHA" ] || {
        echo "STOPP: patched split SHA mismatch"
        echo "got : $got"
        echo "want: $PATCH_SHA"
        exit 1
    }

    su -c "am force-stop '$PKG'" >/dev/null 2>&1 || true

    visible_before="$(su -c "sha256sum '$TARGET' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    echo "Visible XBOT SHA:    $visible_before"

    if [ "$visible_before" = "$PATCH_SHA" ]; then
        echo "PATCH ALREADY ACTIVE"
        return 0
    fi

    unmount_patch

    under="$(su -c "sha256sum '$TARGET' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    echo "Underlying XBOT SHA: $under"

    if [ "$under" = "$PATCH_SHA" ]; then
        echo "PATCH STILL ACTIVE IN MOUNT NAMESPACE"
        return 0
    fi

    [ "$under" = "$ORIG_SHA" ] || {
        echo "STOPP: installert ARM64-split er verken originalbuild eller vår patch."
        echo "got     : $under"
        echo "original: $ORIG_SHA"
        echo "patched : $PATCH_SHA"
        exit 1
    }

    su -c "cp -f '$PATCH' '$TMPAPK'; chmod 0644 '$TMPAPK'"

    ctx="$(su -c "ls -Zd '$TARGET' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    [ -z "$ctx" ] || su -c "chcon '$ctx' '$TMPAPK' 2>/dev/null || true"

    if su -mm -c "mount --bind '$TMPAPK' '$TARGET'"; then
        :
    elif su -c "mount --bind '$TMPAPK' '$TARGET'"; then
        echo "[!] su -mm unavailable; used current root namespace."
    else
        echo "STOPP: bind mount failed"
        exit 1
    fi

    visible="$(su -c "sha256sum '$TARGET' | awk '{print \$1}'")"
    echo "Visible XBOT SHA:    $visible"

    [ "$visible" = "$PATCH_SHA" ] || {
        echo "STOPP: patched split is not visible"
        exit 1
    }

    echo "PATCH ACTIVE"
}

start_server() {
    mode="$1"
    command -v python >/dev/null 2>&1 || pkg install -y python

    stop_server
    rm -f "$HTTPLOG"

    nohup python "$SERVER" \
        --mode "$mode" \
        --root "$ROOT" \
        --host 127.0.0.1 \
        --port "$PORT" \
        --log "$HTTPLOG" \
        >"$HOME/.morosamt-forced-dk-server.out" 2>&1 &

    p=$!
    echo "$p" > "$PIDFILE"

    for _ in $(seq 1 30); do
        if grep -q "LISTEN .*port=$PORT" "$HTTPLOG" 2>/dev/null; then
            break
        fi
        kill -0 "$p" 2>/dev/null || {
            echo "STOPP: local server died"
            cat "$HOME/.morosamt-forced-dk-server.out" 2>/dev/null || true
            exit 1
        }
        sleep 0.1
    done

    grep -q "LISTEN .*port=$PORT" "$HTTPLOG" 2>/dev/null || {
        echo "STOPP: server did not become ready"
        exit 1
    }

    echo "SERVER ACTIVE mode=$mode pid=$p"
    echo "HTTP log: $HTTPLOG"
}

case "$cmd" in
profiles)
    echo "Supported model profiles:"
    echo
    echo "  v2-pro-lr"
    echo "    E-Wheels E2S V2 Pro Long Range"
    echo "    Controller SKU 9444"
    echo "    Verified live DK: model 84a8, id 061007f9, version 33960"
    echo "    probe + current supported"
    echo
    echo "  v2-lr"
    echo "    E-Wheels E2S V2 Long Range"
    echo "    Controller SKU 9433"
    echo "    live DK identity not yet verified in this project"
    echo "    probe/capture supported; current intentionally blocked"
    echo
    echo "Select with:"
    echo "  MOROSAMT_MODEL=v2-pro-lr bash '$0' probe"
    echo "  MOROSAMT_MODEL=v2-lr     bash '$0' probe"
    ;;

install)
    print_profile
    echo
    install_patch
    ;;

probe)
    print_profile
    echo
    install_patch
    start_server probe
    echo
    echo "=== PROBE MODE: NO DK BINARY IS AVAILABLE ==="
    echo "Open XBOT -> connect scooter -> Information -> Forced Firmware upgrade."
    echo "Enter code:"
    echo
    echo "    $CODE"
    echo
    echo "Trigger the lookup. Config.xml may load, but binary requests get intentional 404."
    echo "Then return to Termux and run:"
    echo
    echo "    bash '$0' log"
    ;;

current)
    print_profile
    echo

    if [ "$VERIFIED_CURRENT" != "1" ]; then
        echo "STOPP: current-image ForcedUpgrade is not armed for $MODEL_NAME."
        echo "V2 LR is included for probe/capture, but its live DK identity/image"
        echo "must be recovered before the tool will expose a firmware binary."
        exit 12
    fi

    dk="$ROOT/f/$CODE/DK.bin"
    got="$(sha256sum "$dk" | awk '{print $1}')"
    [ "$got" = "$DK_SHA" ] || {
        echo "STOPP: current DK SHA mismatch"
        exit 1
    }
    [ "$(wc -c < "$dk")" = "$DK_SIZE" ] || {
        echo "STOPP: current DK size mismatch"
        exit 1
    }

    install_patch
    start_server current

    echo
    echo "=== CURRENT DK ARMED ==="
    echo "Model: $MODEL_NAME"
    echo "Code:  $CODE"
    echo "DK:    DK061007f9.bin"
    echo "Size:  $DK_SIZE bytes"
    echo "SHA:   $DK_SHA"
    echo
    echo "Nothing has been flashed yet."
    echo "XBOT must be opened and the Forced Firmware upgrade started manually."
    ;;

log)
    echo "=== $HTTPLOG ==="
    if [ -f "$HTTPLOG" ]; then
        cat "$HTTPLOG"
    else
        echo "No HTTP log yet."
    fi
    ;;

status)
    print_profile
    echo
    echo "=== MOROSAMT FORCED DK STATUS ==="
    echo "Target: $TARGET"
    echo "Target SHA:"
    su -c "sha256sum '$TARGET'" || true
    echo
    echo "Mount:"
    su -c "grep -F ' $TARGET ' /proc/mounts || true" || true
    echo
    if [ -f "$PIDFILE" ]; then
        p="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "Server: RUNNING pid=$p"
        else
            echo "Server: stale PID"
        fi
    else
        echo "Server: STOPPED"
    fi
    echo "Code: $CODE"
    ;;

stop)
    stop_server
    echo "SERVER STOPPED"
    ;;

restore)
    stop_server
    unmount_patch
    su -c "rm -f '$TMPAPK'" >/dev/null 2>&1 || true
    echo "RESTORED ORIGINAL XBOT VIEW"
    su -c "sha256sum '$TARGET'" || true
    ;;

*)
    echo "Usage: $0 {profiles|install|probe|current|log|status|stop|restore}"
    exit 2
    ;;
esac
