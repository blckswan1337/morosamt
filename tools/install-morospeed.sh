#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PKG="no.blckswan.morospeed"
W="$HOME/.morospeed-build"
SRC="$W/src/no/blckswan/morospeed"
CLS="$W/classes"
DEX="$W/dex"
KEY="$HOME/.morospeed-key.jks"
UNSIGNED="$W/u.apk"
ALIGNED="$W/a.apk"
SIGNED="$W/MoroSpeed.apk"
REMOTE="/data/local/tmp/MoroSpeed.apk"
CMD="$PREFIX/bin/morospeed"

mkdir -p "$SRC" "$CLS" "$DEX"
rm -rf "$CLS" "$DEX"
mkdir -p "$CLS" "$DEX"
rm -f "$UNSIGNED" "$ALIGNED" "$SIGNED"

echo "=== MOROSPEED INSTALLER ==="
echo "Installs: morospeed read | morospeed 25 | morospeed 30 | morospeed 32"
echo

need=0
for c in aapt d8 ecj apksigner keytool; do
  command -v "$c" >/dev/null 2>&1 || need=1
done
if [ "$need" -eq 1 ]; then
  pkg install -y aapt d8 ecj apksigner openjdk-21
fi

ANDROID_CLASSES_JAR="$PREFIX/share/java/android.jar"
ANDROID_RES="/system/framework/framework-res.apk"

[ -f "$ANDROID_CLASSES_JAR" ] || {
  echo "STOPP: fant ikke $ANDROID_CLASSES_JAR"
  exit 1
}

if [ ! -r "$ANDROID_RES" ]; then
  ANDROID_RES="$W/framework-res.apk"
  echo "[+] Kopierer framework-res.apk med root ..."
  su -c "cp /system/framework/framework-res.apk '$ANDROID_RES'; chmod 0644 '$ANDROID_RES'"
fi

[ -f "$ANDROID_RES" ] || {
  echo "STOPP: fant ikke framework-res.apk"
  exit 1
}

cat > "$W/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$PKG">
    <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="30" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <application android:label="MoroSpeed" android:allowBackup="false">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
EOF

cat > "$SRC/MainActivity.java" <<'JAVA'
package no.blckswan.morospeed;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.util.UUID;

public class MainActivity extends Activity {
    static final UUID SVC = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
    static final UUID RX  = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
    static final UUID TX  = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
    static final UUID CCCD= UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    // Real E-WHEELS EE..F3 block read, captured on the target controller.
    // Decoded: 55 AA 03 20 61 EE 0C 81 FE
    // Wire: every byte XOR 0x34
    static final byte[] READ_EE_WIRE = hex("619E371455DA38B5CA");

    BluetoothGatt gatt;
    BluetoothGattCharacteristic rx, tx;
    Handler h = new Handler(Looper.getMainLooper());
    TextView view;
    File report;

    boolean servicesReady = false;
    boolean gotInitial = false;
    boolean wrote = false;
    boolean verifying = false;
    boolean done = false;

    String mode = "read";
    int targetRaw = -1;
    String addr;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);

        view = new TextView(this);
        view.setTextSize(15);
        view.setPadding(24, 40, 24, 24);
        setContentView(view);

        report = new File(getExternalFilesDir(null), "MOROSPEED.txt");
        if (report.exists()) report.delete();

        addr = getIntent().getStringExtra("addr");
        mode = getIntent().getStringExtra("mode");
        if (mode == null) mode = "read";
        targetRaw = getIntent().getIntExtra("raw", -1);

        log("=== MOROSPEED ===");
        log("ADDR=" + addr);
        log("PROTO=ScooterIII/HB XOR=0x34 REGISTER=F3");
        log("MODE=" + mode + (targetRaw >= 0 ? " TARGET_RAW=" + targetRaw : ""));
        log("READ_EE_WIRE=" + toHex(READ_EE_WIRE));

        if (!mode.equals("read")) {
            if (targetRaw < 5000 || targetRaw > 60000) {
                fail("TARGET OUT OF RANGE 5.0..60.0 km/h; NOTHING WRITTEN");
                return;
            }
            byte[] w = buildF3Write(targetRaw);
            log("WRITE_WIRE=" + toHex(w));
            log("WRITE_DEC =" + toHex(xor34(w)));
        }

        try {
            BluetoothAdapter a = BluetoothAdapter.getDefaultAdapter();
            if (a == null || !a.isEnabled()) {
                fail("Bluetooth unavailable/off; NOTHING WRITTEN");
                return;
            }

            BluetoothDevice d = a.getRemoteDevice(addr);
            log("CONNECT");
            gatt = d.connectGatt(this, false, cb, BluetoothDevice.TRANSPORT_LE);

            h.postDelayed(new Runnable() {
                public void run() {
                    if (!done) fail("GLOBAL TIMEOUT");
                }
            }, 18000);
        } catch (Throwable t) {
            fail("CONNECT EXCEPTION " + t + "; NOTHING WRITTEN");
        }
    }

    final BluetoothGattCallback cb = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
            log("CONNECTION status=" + status + " state=" + state);

            if (status == BluetoothGatt.GATT_SUCCESS &&
                state == BluetoothProfile.STATE_CONNECTED) {
                log("CONNECTED; discoverServices=" + g.discoverServices());
            } else if (state == BluetoothProfile.STATE_DISCONNECTED && !done) {
                fail("DISCONNECTED status=" + status);
            }
        }

        @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
            log("SERVICES status=" + status);

            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("SERVICE DISCOVERY " + status + "; NOTHING WRITTEN");
                return;
            }

            if (servicesReady) return;
            servicesReady = true;

            BluetoothGattService s = g.getService(SVC);
            if (s == null) {
                fail("NUS SERVICE MISSING; NOTHING WRITTEN");
                return;
            }

            rx = s.getCharacteristic(RX);
            tx = s.getCharacteristic(TX);
            if (rx == null || tx == null) {
                fail("NUS RX/TX MISSING; NOTHING WRITTEN");
                return;
            }

            log("NUS OK RXprops=0x" + Integer.toHexString(rx.getProperties()) +
                " TXprops=0x" + Integer.toHexString(tx.getProperties()));

            if (!g.setCharacteristicNotification(tx, true)) {
                fail("setCharacteristicNotification=false; NOTHING WRITTEN");
                return;
            }

            BluetoothGattDescriptor c = tx.getDescriptor(CCCD);
            if (c == null) {
                fail("CCCD MISSING; NOTHING WRITTEN");
                return;
            }

            c.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            log("CCCD write=" + g.writeDescriptor(c));
        }

        @Override public void onDescriptorWrite(BluetoothGatt g,
                                                BluetoothGattDescriptor d,
                                                int status) {
            log("CCCD status=" + status);
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("CCCD STATUS " + status + "; NOTHING WRITTEN");
                return;
            }

            h.postDelayed(new Runnable() {
                public void run() {
                    if (!done) {
                        log("READ F3 -> " + toHex(READ_EE_WIRE));
                        if (!writeNoResponse(READ_EE_WIRE))
                            fail("READ QUEUE FAILED; NOTHING WRITTEN");
                    }
                }
            }, 250);

            h.postDelayed(new Runnable() {
                public void run() {
                    if (!done && !gotInitial)
                        fail("NO VALID E-WHEELS EE RESPONSE; NOTHING WRITTEN");
                }
            }, 3000);
        }

        @Override public void onCharacteristicWrite(BluetoothGatt g,
                                                    BluetoothGattCharacteristic c,
                                                    int status) {
            log("GATT WRITE status=" + status);
        }

        @Override public void onCharacteristicChanged(BluetoothGatt g,
                                                      BluetoothGattCharacteristic c) {
            byte[] wire = c.getValue();
            if (wire == null || wire.length == 0) return;

            log("NOTIFY_WIRE=" + toHex(wire));
            byte[] d = xor34(wire);
            log("NOTIFY_DEC =" + toHex(d));

            int f3 = parseEeBlockF3(d);
            if (f3 >= 0) handleF3(f3);
        }
    };

    synchronized void handleF3(int raw) {
        if (done) return;

        log("VALID F3_RAW=" + raw + " SPEED=" + formatSpeed(raw) + " km/h");

        if (raw < 5000 || raw > 60000) {
            fail("IMPLAUSIBLE F3 VALUE=" + raw + "; NOTHING WRITTEN");
            return;
        }

        if (!gotInitial) {
            gotInitial = true;
            log("PROTOCOL VERIFIED");
            log("INITIAL F3=" + raw);

            if (mode.equals("read")) {
                success("READ VERIFIED F3=" + raw + " SPEED=" + formatSpeed(raw) + " km/h");
                return;
            }

            if (raw == targetRaw) {
                success("ALREADY SET F3=" + raw + " SPEED=" + formatSpeed(raw) + " km/h");
                return;
            }

            final byte[] write = buildF3Write(targetRaw);

            h.postDelayed(new Runnable() {
                public void run() {
                    if (done) return;
                    wrote = true;
                    log("WRITE -> " + toHex(write));
                    if (!writeNoResponse(write)) {
                        fail("WRITE QUEUE FAILED");
                        return;
                    }

                    h.postDelayed(new Runnable() {
                        public void run() {
                            if (done) return;
                            verifying = true;
                            log("VERIFY READ -> " + toHex(READ_EE_WIRE));
                            if (!writeNoResponse(READ_EE_WIRE))
                                fail("VERIFY READ QUEUE FAILED");
                        }
                    }, 650);

                    h.postDelayed(new Runnable() {
                        public void run() {
                            if (!done && verifying)
                                fail("VERIFY TIMEOUT; target not confirmed");
                        }
                    }, 3500);
                }
            }, 250);
            return;
        }

        if (wrote && verifying) {
            if (raw == targetRaw) {
                success("VERIFIED F3=" + raw + " SPEED=" + formatSpeed(raw) + " km/h");
            } else {
                log("VERIFY OBSERVED F3=" + raw +
                    " SPEED=" + formatSpeed(raw) + " km/h; waiting for target");
            }
        }
    }

    boolean writeNoResponse(byte[] data) {
        if (gatt == null || rx == null) return false;

        rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rx.setValue(data);
        boolean ok = gatt.writeCharacteristic(rx);
        log("QUEUE=" + ok + " WIRE=" + toHex(data) +
            " DEC=" + toHex(xor34(data)));
        return ok;
    }

    static byte[] buildF3Write(int raw) {
        int lo = raw & 0xff;
        int hi = (raw >>> 8) & 0xff;

        byte[] d = new byte[10];
        d[0] = (byte)0x55;
        d[1] = (byte)0xAA;
        d[2] = (byte)0x04;
        d[3] = (byte)0x20;
        d[4] = (byte)0x03;
        d[5] = (byte)0xF3;
        d[6] = (byte)lo;
        d[7] = (byte)hi;

        int sum = 0;
        for (int i = 2; i <= 7; i++)
            sum = (sum + (d[i] & 0xff)) & 0xffff;

        int chk = (0xffff - sum) & 0xffff;
        d[8] = (byte)(chk & 0xff);
        d[9] = (byte)((chk >>> 8) & 0xff);

        return xor34(d);
    }

    int parseEeBlockF3(byte[] d) {
        if (d.length < 20) return -1;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return -1;

        int total = u(d[2]) + 6;
        if (total > d.length || total < 20) return -1;
        if (!checksum55(d, total)) return -1;

        if (u(d[3]) != 0x23) return -1;
        if (u(d[4]) != 0x01) return -1;
        if (u(d[5]) != 0xEE) return -1;

        return u(d[16]) | (u(d[17]) << 8);
    }

    boolean checksum55(byte[] d, int total) {
        int sum = 0;
        for (int i = 2; i < total - 2; i++)
            sum = (sum + u(d[i])) & 0xffff;

        int want = (0xffff - sum) & 0xffff;
        int got = u(d[total - 2]) | (u(d[total - 1]) << 8);
        return want == got;
    }

    void success(String reason) {
        if (done) return;
        done = true;
        log("FINAL: SUCCESS " + reason);
        closeLater();
    }

    void fail(String s) {
        if (done) return;
        done = true;
        log("FINAL: FAIL " + s);
        closeLater();
    }

    void closeLater() {
        h.postDelayed(new Runnable() {
            public void run() {
                try {
                    if (gatt != null) {
                        gatt.disconnect();
                        gatt.close();
                    }
                } catch (Throwable ignored) {}
                finish();
            }
        }, 450);
    }

    synchronized void log(final String s) {
        String line = System.currentTimeMillis() + " " + s + "\n";

        try {
            FileOutputStream f = new FileOutputStream(report, true);
            f.write(line.getBytes("UTF-8"));
            f.close();
        } catch (Throwable ignored) {}

        if (view != null) {
            runOnUiThread(new Runnable() {
                public void run() { view.append(s + "\n"); }
            });
        }
    }

    static String formatSpeed(int raw) {
        int whole = raw / 1000;
        int frac = raw % 1000;
        if (frac == 0) return Integer.toString(whole);
        if (frac % 100 == 0) return whole + "." + (frac / 100);
        if (frac % 10 == 0) {
            int two = frac / 10;
            return whole + "." + (two < 10 ? "0" : "") + two;
        }
        return whole + "." +
            (frac < 100 ? "0" : "") +
            (frac < 10 ? "0" : "") + frac;
    }

    static int u(byte b) { return b & 0xff; }

    static byte[] xor34(byte[] in) {
        byte[] out = new byte[in.length];
        for (int i = 0; i < in.length; i++)
            out[i] = (byte)((in[i] & 0xff) ^ 0x34);
        return out;
    }

    static byte[] hex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < s.length(); i += 2)
            b[i / 2] = (byte)Integer.parseInt(s.substring(i, i + 2), 16);
        return b;
    }

    static String toHex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b)
            s.append(String.format("%02X", x & 0xff));
        return s.toString();
    }
}
JAVA

echo "[1/5] aapt"
aapt package -f -M "$W/AndroidManifest.xml" -I "$ANDROID_RES" -F "$UNSIGNED"

echo "[2/5] ecj"
ecj -proc:none -d "$CLS" -bootclasspath "$ANDROID_CLASSES_JAR" "$SRC/MainActivity.java"

echo "[3/5] d8"
d8 --min-api 23 --lib "$ANDROID_CLASSES_JAR" --output "$DEX" $(find "$CLS" -type f -name '*.class')
(
  cd "$DEX"
  aapt add -f "$UNSIGNED" classes.dex >/dev/null
)

if command -v zipalign >/dev/null 2>&1; then
  zipalign -f 4 "$UNSIGNED" "$ALIGNED"
else
  cp "$UNSIGNED" "$ALIGNED"
fi

if [ ! -f "$KEY" ]; then
  keytool -genkeypair -keystore "$KEY" \
    -storepass blckswan42 -keypass blckswan42 \
    -alias morospeed -keyalg RSA -keysize 2048 -validity 10000 \
    -dname 'CN=MoroSpeed,O=BLCKSWAN,C=NO' \
    >/dev/null 2>&1
fi

echo "[4/5] sign"
apksigner sign \
  --ks "$KEY" \
  --ks-key-alias morospeed \
  --ks-pass pass:blckswan42 \
  --key-pass pass:blckswan42 \
  --out "$SIGNED" "$ALIGNED"

apksigner verify "$SIGNED"

echo "[5/5] install helper APK"
su -c "cp '$SIGNED' '$REMOTE'; chmod 0644 '$REMOTE'; pm install -r '$REMOTE'" || {
  echo "[!] install -r feilet. Gjør clean install av bare MoroSpeed-hjelpeappen."
  su -c "pm uninstall '$PKG' >/dev/null 2>&1 || true; pm install '$REMOTE'"
}

for P in android.permission.ACCESS_FINE_LOCATION android.permission.BLUETOOTH_CONNECT android.permission.BLUETOOTH_SCAN; do
  su -c "pm grant '$PKG' '$P'" >/dev/null 2>&1 || true
done

cat > "$CMD" <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -u

PKG="no.blckswan.morospeed"
ADDR_DEFAULT="EC:6E:86:06:32:29"
ADDR="${MOROSPEED_ADDR:-$ADDR_DEFAULT}"
REPORT="/sdcard/Android/data/$PKG/files/MOROSPEED.txt"
OUT="/sdcard/Download/MOROSPEED.txt"

usage() {
  cat <<EOF
MoroSpeed

Bruk:
  morospeed read
  morospeed 25
  morospeed 30
  morospeed 32
  morospeed 30.5

Valgfri BLE-adresse:
  MOROSPEED_ADDR=AA:BB:CC:DD:EE:FF morospeed read
EOF
}

ARG="${1:-}"
[ -n "$ARG" ] || { usage; exit 1; }

case "$ARG" in
  -h|--help|help)
    usage
    exit 0
    ;;
  read)
    MODE="read"
    RAW="-1"
    ;;
  *)
    if ! printf '%s\n' "$ARG" | grep -Eq '^[0-9]+([.][0-9]{1,3})?$'; then
      echo "Ugyldig hastighet: $ARG"
      usage
      exit 1
    fi

    RAW="$(awk -v s="$ARG" 'BEGIN { printf "%.0f", s * 1000 }')"

    if [ "$RAW" -lt 5000 ] || [ "$RAW" -gt 60000 ]; then
      echo "Tillatt område i verktøyet: 5.0–60.0 km/t"
      exit 1
    fi

    MODE="set"
    ;;
esac

# Sørg for at bare MoroSpeed eier GATT-linken.
for P in \
  com.HB.EWHEELS \
  com.mini.xbot \
  no.nordicsemi.android.mcp \
  no.blckswan.xbot30real \
  no.blckswan.xbot30hci
do
  su -c "am force-stop '$P'" >/dev/null 2>&1 || true
done

su -c "am force-stop '$PKG'; rm -f '$REPORT' '$OUT'" >/dev/null 2>&1 || true

if [ "$MODE" = "read" ]; then
  echo "MoroSpeed: leser F3 fra $ADDR ..."
  su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR' --es mode read" >/dev/null || exit 1
else
  echo "MoroSpeed: setter $ARG km/t på $ADDR ..."
  su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR' --es mode set --ei raw '$RAW'" >/dev/null || exit 1
fi

for i in $(seq 1 22); do
  if su -c "test -s '$REPORT'" >/dev/null 2>&1 &&
     su -c "grep -q 'FINAL:' '$REPORT'" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if su -c "test -s '$REPORT'" >/dev/null 2>&1; then
  su -c "cp '$REPORT' '$OUT'; chmod 0644 '$OUT'" >/dev/null 2>&1 || true

  echo
  su -c "grep -E '^(.* )(VALID F3_RAW=|INITIAL F3=|WRITE ->|FINAL:)' '$REPORT'" \
    | sed -E 's/^[0-9]+ //' || su -c "tail -n 12 '$REPORT'"

  echo
  echo "Rapport: $OUT"

  if su -c "grep -q 'FINAL: SUCCESS' '$REPORT'"; then
    exit 0
  fi
  exit 2
fi

echo "Ingen rapport fra hjelpeappen."
exit 3
SH

chmod +x "$CMD"

echo
echo "=== FERDIG ==="
echo "Kommando installert:"
echo "  $CMD"
echo
echo "Prøv:"
echo "  morospeed read"
echo "  morospeed 25"
echo "  morospeed 30"
echo "  morospeed 32"
