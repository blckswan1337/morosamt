#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MoroSpeed ALL30 v2
# Key fix: controller only accepts a speed-slot write when the corresponding
# drive mode (7E) is active.
#
# Mapping recovered from E-WHEELS native code:
#   7E=0 -> F0
#   7E=1 -> EF
#   7E=2 -> F1
#   7E=3 -> F3
#
# Sequence:
#   read original 7E
#   read EE..F3
#   mode0 -> F0=30 -> verify
#   mode1 -> EF=30 -> verify
#   mode2 -> F1=30 -> verify
#   mode3 -> F3=30 -> verify
#   restore original 7E
#   final verify of all four slots

PKG="no.blckswan.morospeedall30v2"
ADDR="${MOROSPEED_ADDR:-EC:6E:86:06:32:29}"

W="$HOME/.morospeed-all30-v2-build"
SRC="$W/src/no/blckswan/morospeedall30v2"
CLS="$W/classes"
DEX="$W/dex"
KEY="$HOME/.morospeed-all30-v2-key.jks"
UNSIGNED="$W/u.apk"
ALIGNED="$W/a.apk"
SIGNED="$W/MoroSpeed-ALL30-v2.apk"
REMOTE="/data/local/tmp/MoroSpeed-ALL30-v2.apk"
REPORT_ANDROID="/sdcard/Android/data/$PKG/files/MOROSPEED_ALL30_V2.txt"
REPORT_OUT="/sdcard/Download/MOROSPEED_ALL30_V2.txt"

mkdir -p "$SRC" "$CLS" "$DEX"
rm -rf "$CLS" "$DEX"
mkdir -p "$CLS" "$DEX"
rm -f "$UNSIGNED" "$ALIGNED" "$SIGNED"

echo "=== MOROSPEED ALL30 v2 ==="
echo "Target: $ADDR"
echo "Mode-aware writes: 0/F0  1/EF  2/F1  3/F3"
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
    <application android:label="MoroSpeed ALL30 v2" android:allowBackup="false">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
EOF

cat > "$SRC/MainActivity.java" <<'JAVA'
package no.blckswan.morospeedall30v2;

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

    // Captured E-WHEELS reads.
    static final byte[] READ_MODE_WIRE = hex("619E3714554F3EC2CA");
    // decoded: 55 AA 03 20 61 7B 0A F6 FE
    static final byte[] READ_EE_WIRE   = hex("619E371455DA38B5CA");
    // decoded: 55 AA 03 20 61 EE 0C 81 FE

    static final double SPEED_CONSTANT = 5794.652832;
    static final int TARGET_KMH = 30;
    static final int TARGET_F3 = 30000;

    BluetoothGatt gatt;
    BluetoothGattCharacteristic rx, tx;
    Handler h = new Handler(Looper.getMainLooper());
    TextView view;
    File report;

    String addr;
    boolean ready = false;
    boolean done = false;

    int originalMode = -1;
    int ee = -1;
    int targetScaled = -1;

    // State machine.
    // 0 read original mode
    // 1 read initial EE
    // 10 waiting verify F0
    // 11 waiting verify EF
    // 12 waiting verify F1
    // 13 waiting verify F3
    // 20 waiting restored mode
    // 21 waiting final EE
    int state = 0;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);

        view = new TextView(this);
        view.setTextSize(15);
        view.setPadding(24, 40, 24, 24);
        setContentView(view);

        report = new File(getExternalFilesDir(null), "MOROSPEED_ALL30_V2.txt");
        if (report.exists()) report.delete();

        addr = getIntent().getStringExtra("addr");
        if (addr == null || addr.length() < 17)
            addr = "EC:6E:86:06:32:29";

        log("=== MOROSPEED ALL30 v2 ===");
        log("ADDR=" + addr);
        log("PROTO=ScooterIII/HB XOR=0x34");
        log("MAP 7E=0->F0 7E=1->EF 7E=2->F1 7E=3->F3");
        log("TARGET=30 km/h");

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
            }, 30000);

        } catch (Throwable t) {
            fail("CONNECT EXCEPTION " + t + "; NOTHING WRITTEN");
        }
    }

    final BluetoothGattCallback cb = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            log("CONNECTION status=" + status + " state=" + newState);

            if (status == BluetoothGatt.GATT_SUCCESS &&
                newState == BluetoothProfile.STATE_CONNECTED) {
                log("CONNECTED; discoverServices=" + g.discoverServices());
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED && !done) {
                fail("DISCONNECTED status=" + status);
            }
        }

        @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
            log("SERVICES status=" + status);

            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("SERVICE DISCOVERY " + status + "; NOTHING WRITTEN");
                return;
            }
            if (ready) return;
            ready = true;

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
                    log("READ ORIGINAL MODE");
                    send(READ_MODE_WIRE);
                }
            }, 250);
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

            int mode = parseModeBlock(dec);
            if (mode >= 0) {
                handleMode(mode);
                return;
            }

            int[] slots = parseEeBlock(dec);
            if (slots != null) {
                handleEe(slots);
            }
        }
    };

    synchronized void handleMode(int mode) {
        if (done) return;
        log("VALID MODE 7E=" + mode);

        if (state == 0) {
            if (mode < 0 || mode > 3) {
                fail("ORIGINAL MODE OUT OF RANGE; NOTHING WRITTEN");
                return;
            }

            originalMode = mode;
            log("ORIGINAL MODE=" + originalMode);
            state = 1;

            h.postDelayed(new Runnable() {
                @Override public void run() {
                    log("READ INITIAL EE..F3");
                    send(READ_EE_WIRE);
                }
            }, 250);
            return;
        }

        if (state == 20) {
            if (mode != originalMode) {
                fail("RESTORE MODE VERIFY FAILED got=" + mode +
                     " expected=" + originalMode);
                return;
            }

            log("ORIGINAL MODE RESTORED=" + mode);
            state = 21;

            h.postDelayed(new Runnable() {
                @Override public void run() {
                    log("FINAL READ EE..F3");
                    send(READ_EE_WIRE);
                }
            }, 250);
        }
    }

    synchronized void handleEe(int[] s) {
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

        if (state == 1) {
            if (curEE < 50 || curEE > 1000 ||
                curEF < 0 || curEF > 5000 ||
                curF0 < 0 || curF0 > 5000 ||
                curF1 < 0 || curF1 > 5000 ||
                curF3 < 1000 || curF3 > 60000) {
                fail("EE BLOCK SHAPE UNEXPECTED; NOTHING WRITTEN");
                return;
            }

            ee = curEE;
            targetScaled = (int)((TARGET_KMH * SPEED_CONSTANT) / ee);

            if (targetScaled < 100 || targetScaled > 5000) {
                fail("CALCULATED TARGET RAW OUT OF RANGE; NOTHING WRITTEN");
                return;
            }

            log("PROTOCOL VERIFIED");
            log("WHEEL_EE=" + ee);
            log("TARGET_SCALED_RAW=" + targetScaled +
                " (~" + one(kmhFromScaled(targetScaled, ee)) + " km/h)");
            log("TARGET_F3_RAW=" + TARGET_F3);

            doSlot(0, 0xF0, targetScaled, 10);
            return;
        }

        if (state == 10) {
            if (curF0 != targetScaled) {
                fail("F0 VERIFY FAILED got=" + curF0 +
                     " expected=" + targetScaled);
                return;
            }
            log("F0 VERIFIED=" + curF0);
            doSlot(1, 0xEF, targetScaled, 11);
            return;
        }

        if (state == 11) {
            if (curEF != targetScaled) {
                fail("EF VERIFY FAILED got=" + curEF +
                     " expected=" + targetScaled);
                return;
            }
            log("EF VERIFIED=" + curEF);
            doSlot(2, 0xF1, targetScaled, 12);
            return;
        }

        if (state == 12) {
            if (curF1 != targetScaled) {
                fail("F1 VERIFY FAILED got=" + curF1 +
                     " expected=" + targetScaled);
                return;
            }
            log("F1 VERIFIED=" + curF1);
            doSlot(3, 0xF3, TARGET_F3, 13);
            return;
        }

        if (state == 13) {
            if (curF3 != TARGET_F3) {
                fail("F3 VERIFY FAILED got=" + curF3 +
                     " expected=" + TARGET_F3);
                return;
            }

            log("F3 VERIFIED=" + curF3);
            log("RESTORE ORIGINAL MODE " + originalMode);
            state = 20;

            final byte[] restore = buildWrite(0x7E, originalMode);
            h.postDelayed(new Runnable() {
                @Override public void run() {
                    send(restore);

                    h.postDelayed(new Runnable() {
                        @Override public void run() {
                            log("VERIFY RESTORED MODE");
                            send(READ_MODE_WIRE);
                        }
                    }, 450);
                }
            }, 250);
            return;
        }

        if (state == 21) {
            boolean ok =
                curEF == targetScaled &&
                curF0 == targetScaled &&
                curF1 == targetScaled &&
                curF3 == TARGET_F3;

            log("FINAL SPEEDS " +
                "EF=" + one(kmhFromScaled(curEF, ee)) +
                " F0=" + one(kmhFromScaled(curF0, ee)) +
                " F1=" + one(kmhFromScaled(curF1, ee)) +
                " F3=" + one(curF3 / 1000.0));

            if (ok) {
                success("ALL FOUR VERIFIED + MODE RESTORED " +
                        "EF=" + curEF +
                        " F0=" + curF0 +
                        " F1=" + curF1 +
                        " F3=" + curF3 +
                        " MODE=" + originalMode);
            } else {
                fail("FINAL VERIFY MISMATCH " +
                     "EF=" + curEF + "/" + targetScaled + " " +
                     "F0=" + curF0 + "/" + targetScaled + " " +
                     "F1=" + curF1 + "/" + targetScaled + " " +
                     "F3=" + curF3 + "/" + TARGET_F3);
            }
        }
    }

    void doSlot(final int mode,
                final int reg,
                final int raw,
                final int verifyState) {
        if (done) return;

        final byte[] modeFrame = buildWrite(0x7E, mode);
        final byte[] slotFrame = buildWrite(reg, raw);

        log("SELECT MODE " + mode +
            " DEC=" + toHex(xor34(modeFrame)));

        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done) return;
                send(modeFrame);

                h.postDelayed(new Runnable() {
                    @Override public void run() {
                        if (done) return;

                        log("WRITE SLOT reg=0x" +
                            Integer.toHexString(reg).toUpperCase() +
                            " raw=" + raw +
                            " DEC=" + toHex(xor34(slotFrame)));

                        send(slotFrame);

                        h.postDelayed(new Runnable() {
                            @Override public void run() {
                                if (done) return;
                                state = verifyState;
                                log("VERIFY SLOT 0x" +
                                    Integer.toHexString(reg).toUpperCase());
                                send(READ_EE_WIRE);
                            }
                        }, 650);
                    }
                }, 500);
            }
        }, 250);
    }

    boolean send(byte[] data) {
        if (done || gatt == null || rx == null) return false;

        rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rx.setValue(data);

        boolean ok = gatt.writeCharacteristic(rx);
        log("QUEUE=" + ok +
            " WIRE=" + toHex(data) +
            " DEC=" + toHex(xor34(data)));

        if (!ok)
            fail("GATT QUEUE FAILED");

        return ok;
    }

    static byte[] buildWrite(int reg, int raw) {
        byte[] d = new byte[10];

        d[0] = (byte)0x55;
        d[1] = (byte)0xAA;
        d[2] = (byte)0x04;
        d[3] = (byte)0x20;
        d[4] = (byte)0x03;
        d[5] = (byte)reg;
        d[6] = (byte)(raw & 0xFF);
        d[7] = (byte)((raw >>> 8) & 0xFF);

        int sum = 0;
        for (int i = 2; i <= 7; i++)
            sum = (sum + (d[i] & 0xFF)) & 0xFFFF;

        int chk = (0xFFFF - sum) & 0xFFFF;
        d[8] = (byte)(chk & 0xFF);
        d[9] = (byte)((chk >>> 8) & 0xFF);

        return xor34(d);
    }

    // Response to captured 7B read:
    // 55 AA 0C 23 01 7B
    // 7B(lo hi) 7C(lo hi) 7D(lo hi) 7E(lo hi) 7F(lo hi)
    // checksum(lo hi)
    int parseModeBlock(byte[] d) {
        if (d.length < 18) return -1;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return -1;

        int total = u(d[2]) + 6;
        if (total > d.length || total < 18) return -1;
        if (!checksum55(d, total)) return -1;

        if (u(d[3]) != 0x23 ||
            u(d[4]) != 0x01 ||
            u(d[5]) != 0x7B) return -1;

        return u(d[12]) | (u(d[13]) << 8);
    }

    // Returns EE,EF,F0,F1,F2,F3.
    int[] parseEeBlock(byte[] d) {
        if (d.length < 20) return null;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return null;

        int total = u(d[2]) + 6;
        if (total > d.length || total < 20) return null;
        if (!checksum55(d, total)) return null;

        if (u(d[3]) != 0x23 ||
            u(d[4]) != 0x01 ||
            u(d[5]) != 0xEE) return null;

        int[] out = new int[6];
        out[0] = u(d[6])  | (u(d[7])  << 8);
        out[1] = u(d[8])  | (u(d[9])  << 8);
        out[2] = u(d[10]) | (u(d[11]) << 8);
        out[3] = u(d[12]) | (u(d[13]) << 8);
        out[4] = u(d[14]) | (u(d[15]) << 8);
        out[5] = u(d[16]) | (u(d[17]) << 8);
        return out;
    }

    boolean checksum55(byte[] d, int total) {
        int sum = 0;
        for (int i = 2; i < total - 2; i++)
            sum = (sum + u(d[i])) & 0xFFFF;

        int want = (0xFFFF - sum) & 0xFFFF;
        int got = u(d[total - 2]) | (u(d[total - 1]) << 8);

        return want == got;
    }

    static double kmhFromScaled(int raw, int ee) {
        return raw * ((double)ee / SPEED_CONSTANT);
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

    void fail(String reason) {
        if (done) return;
        done = true;
        log("FINAL: FAIL " + reason);
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
        return b & 0xFF;
    }

    static byte[] xor34(byte[] in) {
        byte[] out = new byte[in.length];
        for (int i = 0; i < in.length; i++)
            out[i] = (byte)((in[i] & 0xFF) ^ 0x34);
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
            s.append(String.format("%02X", x & 0xFF));
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
    -alias morospeedall30v2 \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname 'CN=MoroSpeed ALL30 v2,O=BLCKSWAN,C=NO' \
    >/dev/null 2>&1
fi

echo "[4/5] sign"
apksigner sign \
  --ks "$KEY" \
  --ks-key-alias morospeedall30v2 \
  --ks-pass pass:blckswan42 \
  --key-pass pass:blckswan42 \
  --out "$SIGNED" \
  "$ALIGNED"

apksigner verify "$SIGNED"

echo "[5/5] install + run"

for P in \
  com.HB.EWHEELS \
  com.mini.xbot \
  no.nordicsemi.android.mcp \
  no.blckswan.xbot30real \
  no.blckswan.xbot30hci \
  no.blckswan.morospeed \
  no.blckswan.morospeedall30
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
echo "[+] Starter mode-aware ALL30 mot $ADDR ..."
su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR'" >/dev/null

for i in $(seq 1 35); do
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
    echo "=== ALL30 v2 VERIFIED ==="
    exit 0
  fi

  exit 2
fi

echo "Ingen rapport fra ALL30 v2-hjelpeappen."
exit 3
