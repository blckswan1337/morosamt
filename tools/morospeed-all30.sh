#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MoroSpeed ALL30
# Sets the four verified speed slots EF/F0/F1/F3 to ~30 km/h,
# using EE wheel factor for EF/F0/F1 and 30000 raw for F3.
#
# Target protocol:
#   Nordic UART Service
#   decoded frame 55 AA ...
#   BLE wire XOR 0x34
#
# No reboot. No blind write:
# it first requires a valid EE..F3 read, then writes, then verifies all four.

PKG="no.blckswan.morospeedall30"
ADDR="${MOROSPEED_ADDR:-EC:6E:86:06:32:29}"

W="$HOME/.morospeed-all30-build"
SRC="$W/src/no/blckswan/morospeedall30"
CLS="$W/classes"
DEX="$W/dex"
KEY="$HOME/.morospeed-all30-key.jks"
UNSIGNED="$W/u.apk"
ALIGNED="$W/a.apk"
SIGNED="$W/MoroSpeed-ALL30.apk"
REMOTE="/data/local/tmp/MoroSpeed-ALL30.apk"
REPORT_ANDROID="/sdcard/Android/data/$PKG/files/MOROSPEED_ALL30.txt"
REPORT_OUT="/sdcard/Download/MOROSPEED_ALL30.txt"

mkdir -p "$SRC" "$CLS" "$DEX"
rm -rf "$CLS" "$DEX"
mkdir -p "$CLS" "$DEX"
rm -f "$UNSIGNED" "$ALIGNED" "$SIGNED"

echo "=== MOROSPEED ALL30 ==="
echo "Target: $ADDR"
echo "Slots: EF F0 F1 F3 -> 30 km/h"
echo

need=0
for c in aapt d8 ecj apksigner keytool; do
  command -v "$c" >/dev/null 2>&1 || need=1
done

if [ "$need" -eq 1 ]; then
  echo "[+] Installerer byggverktøy ..."
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
    <application android:label="MoroSpeed ALL30" android:allowBackup="false">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
EOF

cat > "$SRC/MainActivity.java" <<'JAVA'
package no.blckswan.morospeedall30;

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

    // Real captured E-WHEELS request:
    // decoded = 55 AA 03 20 61 EE 0C 81 FE
    // wire    = decoded XOR 34
    static final byte[] READ_EE_WIRE = hex("619E371455DA38B5CA");

    static final int TARGET_KMH = 30;
    static final int TARGET_F3  = 30000;

    // Native E-WHEELS wheel/speed constant recovered during RE.
    static final double SPEED_CONSTANT = 5794.652832;

    BluetoothGatt gatt;
    BluetoothGattCharacteristic rx, tx;
    Handler h = new Handler(Looper.getMainLooper());
    TextView view;
    File report;

    String addr;
    boolean servicesReady = false;
    boolean gotInitial = false;
    boolean writeSequenceStarted = false;
    boolean verifying = false;
    boolean done = false;

    int ee = -1;
    int targetScaled = -1;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);

        view = new TextView(this);
        view.setTextSize(15);
        view.setPadding(24, 40, 24, 24);
        setContentView(view);

        report = new File(getExternalFilesDir(null), "MOROSPEED_ALL30.txt");
        if (report.exists()) report.delete();

        addr = getIntent().getStringExtra("addr");
        if (addr == null || addr.length() < 17)
            addr = "EC:6E:86:06:32:29";

        log("=== MOROSPEED ALL30 ===");
        log("ADDR=" + addr);
        log("PROTO=ScooterIII/HB XOR=0x34");
        log("TARGET=30 km/h SLOTS=EF,F0,F1,F3");
        log("READ_EE_WIRE=" + toHex(READ_EE_WIRE));

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
                @Override public void run() {
                    if (!done) fail("GLOBAL TIMEOUT");
                }
            }, 22000);

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
                @Override public void run() {
                    if (!done) {
                        log("INITIAL READ EE..F3");
                        if (!writeNoResponse(READ_EE_WIRE))
                            fail("INITIAL READ QUEUE FAILED; NOTHING WRITTEN");
                    }
                }
            }, 250);

            h.postDelayed(new Runnable() {
                @Override public void run() {
                    if (!done && !gotInitial)
                        fail("NO VALID EE..F3 RESPONSE; NOTHING WRITTEN");
                }
            }, 3200);
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
            byte[] dec = xor34(wire);
            log("NOTIFY_DEC =" + toHex(dec));

            int[] slots = parseEeBlock(dec);
            if (slots != null) handleEeBlock(slots);
        }
    };

    synchronized void handleEeBlock(int[] s) {
        if (done) return;

        int curEE = s[0];
        int curEF = s[1];
        int curF0 = s[2];
        int curF1 = s[3];
        int curF2 = s[4];
        int curF3 = s[5];

        log("EE=" + curEE +
            " EF=" + curEF +
            " F0=" + curF0 +
            " F1=" + curF1 +
            " F2=" + curF2 +
            " F3=" + curF3);

        if (!gotInitial) {
            // Safety gate: EE must be a sane nonzero wheel factor.
            if (curEE < 50 || curEE > 1000) {
                fail("IMPLAUSIBLE EE=" + curEE + "; NOTHING WRITTEN");
                return;
            }

            // Existing speed slots must also be plausible enough that we know
            // this is the expected controller/register block.
            if (curEF < 0 || curEF > 5000 ||
                curF0 < 0 || curF0 > 5000 ||
                curF1 < 0 || curF1 > 5000 ||
                curF3 < 1000 || curF3 > 60000) {
                fail("EE BLOCK SHAPE UNEXPECTED; NOTHING WRITTEN");
                return;
            }

            gotInitial = true;
            ee = curEE;

            // E-WHEELS effectively converts km/h to these raw slots by
            // speed * constant / EE, then integer truncation.
            targetScaled = (int)((TARGET_KMH * SPEED_CONSTANT) / ee);

            log("PROTOCOL VERIFIED");
            log("WHEEL_EE=" + ee);
            log("TARGET_SCALED_RAW=" + targetScaled +
                " (~" + fmtKmhFromScaled(targetScaled, ee) + " km/h)");
            log("TARGET_F3_RAW=" + TARGET_F3);

            if (targetScaled < 100 || targetScaled > 5000) {
                fail("CALCULATED TARGET RAW OUT OF RANGE; NOTHING WRITTEN");
                return;
            }

            startWrites();
            return;
        }

        if (verifying) {
            double efK = kmhFromScaled(curEF, ee);
            double f0K = kmhFromScaled(curF0, ee);
            double f1K = kmhFromScaled(curF1, ee);

            log("VERIFY SPEEDS EF=" + one(efK) +
                " F0=" + one(f0K) +
                " F1=" + one(f1K) +
                " F3=" + one(curF3 / 1000.0));

            boolean ok =
                curEF == targetScaled &&
                curF0 == targetScaled &&
                curF1 == targetScaled &&
                curF3 == TARGET_F3;

            if (ok) {
                success("ALL FOUR VERIFIED " +
                        "EF=" + curEF + " F0=" + curF0 +
                        " F1=" + curF1 + " F3=" + curF3);
            } else {
                fail("VERIFY MISMATCH " +
                     "EF=" + curEF + "/" + targetScaled + " " +
                     "F0=" + curF0 + "/" + targetScaled + " " +
                     "F1=" + curF1 + "/" + targetScaled + " " +
                     "F3=" + curF3 + "/" + TARGET_F3);
            }
        }
    }

    void startWrites() {
        if (writeSequenceStarted || done) return;
        writeSequenceStarted = true;

        final byte[] wEF = buildWrite(0xEF, targetScaled);
        final byte[] wF0 = buildWrite(0xF0, targetScaled);
        final byte[] wF1 = buildWrite(0xF1, targetScaled);
        final byte[] wF3 = buildWrite(0xF3, TARGET_F3);

        log("WRITE_EF_DEC=" + toHex(xor34(wEF)));
        log("WRITE_F0_DEC=" + toHex(xor34(wF0)));
        log("WRITE_F1_DEC=" + toHex(xor34(wF1)));
        log("WRITE_F3_DEC=" + toHex(xor34(wF3)));

        scheduleWrite("EF", wEF, 250);
        scheduleWrite("F0", wF0, 650);
        scheduleWrite("F1", wF1, 1050);
        scheduleWrite("F3", wF3, 1450);

        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done) return;
                verifying = true;
                log("VERIFY READ EE..F3");
                if (!writeNoResponse(READ_EE_WIRE))
                    fail("VERIFY READ QUEUE FAILED");
            }
        }, 2250);

        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (!done && verifying)
                    fail("VERIFY TIMEOUT");
            }
        }, 6000);
    }

    void scheduleWrite(final String name, final byte[] frame, long delay) {
        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done) return;
                log("WRITE " + name + " WIRE=" + toHex(frame));
                if (!writeNoResponse(frame))
                    fail("WRITE " + name + " QUEUE FAILED");
            }
        }, delay);
    }

    boolean writeNoResponse(byte[] data) {
        if (gatt == null || rx == null) return false;

        rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rx.setValue(data);

        boolean ok = gatt.writeCharacteristic(rx);
        log("QUEUE=" + ok +
            " WIRE=" + toHex(data) +
            " DEC=" + toHex(xor34(data)));
        return ok;
    }

    static byte[] buildWrite(int reg, int raw) {
        int lo = raw & 0xff;
        int hi = (raw >>> 8) & 0xff;

        byte[] d = new byte[10];
        d[0] = (byte)0x55;
        d[1] = (byte)0xAA;
        d[2] = (byte)0x04;
        d[3] = (byte)0x20;
        d[4] = (byte)0x03;
        d[5] = (byte)reg;
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

    // Returns EE,EF,F0,F1,F2,F3.
    int[] parseEeBlock(byte[] d) {
        if (d.length < 20) return null;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return null;

        int total = u(d[2]) + 6;
        if (total > d.length || total < 20) return null;
        if (!checksum55(d, total)) return null;

        if (u(d[3]) != 0x23) return null;
        if (u(d[4]) != 0x01) return null;
        if (u(d[5]) != 0xEE) return null;

        int[] out = new int[6];
        out[0] = u(d[6])  | (u(d[7])  << 8); // EE
        out[1] = u(d[8])  | (u(d[9])  << 8); // EF
        out[2] = u(d[10]) | (u(d[11]) << 8); // F0
        out[3] = u(d[12]) | (u(d[13]) << 8); // F1
        out[4] = u(d[14]) | (u(d[15]) << 8); // F2
        out[5] = u(d[16]) | (u(d[17]) << 8); // F3
        return out;
    }

    boolean checksum55(byte[] d, int total) {
        int sum = 0;
        for (int i = 2; i < total - 2; i++)
            sum = (sum + u(d[i])) & 0xffff;

        int want = (0xffff - sum) & 0xffff;
        int got  = u(d[total - 2]) | (u(d[total - 1]) << 8);
        return want == got;
    }

    static double kmhFromScaled(int raw, int ee) {
        return raw * ((double)ee / SPEED_CONSTANT);
    }

    static String fmtKmhFromScaled(int raw, int ee) {
        return one(kmhFromScaled(raw, ee));
    }

    static String one(double v) {
        long x = Math.round(v * 10.0);
        return (x / 10) + "." + Math.abs(x % 10);
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
            @Override public void run() {
                try {
                    if (gatt != null) {
                        gatt.disconnect();
                        gatt.close();
                    }
                } catch (Throwable ignored) {}
                finish();
            }
        }, 500);
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
                @Override public void run() {
                    view.append(s + "\n");
                }
            });
        }
    }

    static int u(byte b) {
        return b & 0xff;
    }

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
aapt package -f \
  -M "$W/AndroidManifest.xml" \
  -I "$ANDROID_RES" \
  -F "$UNSIGNED"

echo "[2/5] ecj"
ecj -proc:none \
  -d "$CLS" \
  -bootclasspath "$ANDROID_CLASSES_JAR" \
  "$SRC/MainActivity.java"

echo "[3/5] d8"
d8 \
  --min-api 23 \
  --lib "$ANDROID_CLASSES_JAR" \
  --output "$DEX" \
  $(find "$CLS" -type f -name '*.class')

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
  keytool -genkeypair \
    -keystore "$KEY" \
    -storepass blckswan42 \
    -keypass blckswan42 \
    -alias morospeedall30 \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname 'CN=MoroSpeed ALL30,O=BLCKSWAN,C=NO' \
    >/dev/null 2>&1
fi

echo "[4/5] sign"
apksigner sign \
  --ks "$KEY" \
  --ks-key-alias morospeedall30 \
  --ks-pass pass:blckswan42 \
  --key-pass pass:blckswan42 \
  --out "$SIGNED" \
  "$ALIGNED"

apksigner verify "$SIGNED"

echo "[5/5] install + run"

# Free the controller from apps that may already hold its GATT connection.
for P in \
  com.HB.EWHEELS \
  com.mini.xbot \
  no.nordicsemi.android.mcp \
  no.blckswan.xbot30real \
  no.blckswan.xbot30hci \
  no.blckswan.morospeed
do
  su -c "am force-stop '$P'" >/dev/null 2>&1 || true
done

su -c "cp '$SIGNED' '$REMOTE'; chmod 0644 '$REMOTE'; pm install -r '$REMOTE'" || {
  su -c "pm uninstall '$PKG' >/dev/null 2>&1 || true; pm install '$REMOTE'"
}

for P in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.BLUETOOTH_CONNECT \
  android.permission.BLUETOOTH_SCAN
do
  su -c "pm grant '$PKG' '$P'" >/dev/null 2>&1 || true
done

su -c "am force-stop '$PKG'; rm -f '$REPORT_ANDROID' '$REPORT_OUT'" >/dev/null 2>&1 || true

echo
echo "[+] Starter ALL30 mot $ADDR ..."
su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR'" >/dev/null

for i in $(seq 1 25); do
  if su -c "test -s '$REPORT_ANDROID'" >/dev/null 2>&1 &&
     su -c "grep -q 'FINAL:' '$REPORT_ANDROID'" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if su -c "test -s '$REPORT_ANDROID'" >/dev/null 2>&1; then
  su -c "cp '$REPORT_ANDROID' '$REPORT_OUT'; chmod 0644 '$REPORT_OUT'" >/dev/null 2>&1 || true

  echo
  echo "=== RESULTAT ==="
  su -c "cat '$REPORT_ANDROID'"

  echo
  echo "Rapport:"
  echo "  $REPORT_OUT"

  if su -c "grep -q 'FINAL: SUCCESS' '$REPORT_ANDROID'"; then
    echo
    echo "=== ALL30 VERIFIED ==="
    exit 0
  fi

  exit 2
fi

echo "Ingen rapport fra ALL30-hjelpeappen."
exit 3
