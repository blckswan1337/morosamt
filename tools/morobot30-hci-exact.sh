#!/data/data/com.termux/files/usr/bin/bash
set -u

ADDR="${1:-EC:6E:86:06:32:29}"
PKG="no.blckswan.xbot30hci"
W="$HOME/.xbot30hci"
SRC="$W/src/no/blckswan/xbot30hci"
CLS="$W/classes"
DEX="$W/dex"
KEY="$HOME/.xbot30hci-key.jks"
UNSIGNED="$W/u.apk"
ALIGNED="$W/a.apk"
SIGNED="$W/XBOT30_HCI.apk"
REMOTE="/data/local/tmp/XBOT30_HCI.apk"
REPORT="/sdcard/Android/data/$PKG/files/MOROBOT30_HCI_EXACT.txt"
OUT="/sdcard/Download/MOROBOT30_HCI_EXACT.txt"

mkdir -p "$SRC" "$CLS" "$DEX"
rm -rf "$CLS" "$DEX"
mkdir -p "$CLS" "$DEX"
rm -f "$UNSIGNED" "$ALIGNED" "$SIGNED"

echo '=== XBOT / E-WHEELS 30 HCI-EXACT ==='
echo "BLE: $ADDR"
echo 'Protocol: ScooterIII/HB, XOR 0x34, register F3'
echo 'Safety gate: read F3 first, write only after a valid E-WHEELS block reply.'
echo

need=0
for c in aapt d8 ecj apksigner keytool; do
  command -v "$c" >/dev/null 2>&1 || need=1
done
if [ "$need" -eq 1 ]; then
  pkg install -y aapt d8 ecj apksigner openjdk-21 || exit 1
fi

ANDROID_CLASSES_JAR="$PREFIX/share/java/android.jar"
ANDROID_RES="/system/framework/framework-res.apk"

[ -f "$ANDROID_CLASSES_JAR" ] || {
  echo "STOPP: fant ikke $ANDROID_CLASSES_JAR"
  exit 1
}

if [ ! -r "$ANDROID_RES" ]; then
  ANDROID_RES="$W/framework-res.apk"
  echo '[+] Kopierer framework-res.apk med root ...'
  su -c "cp /system/framework/framework-res.apk '$ANDROID_RES'; chmod 0644 '$ANDROID_RES'" || exit 1
fi

[ -f "$ANDROID_RES" ] || {
  echo 'STOPP: fant ikke framework-res.apk'
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
    <application android:label="XBOT 30 HCI" android:allowBackup="false">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
EOF

cat > "$SRC/MainActivity.java" <<'JAVA'
package no.blckswan.xbot30hci;

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

    /*
     * Captured directly from E-WHEELS talking to EC:6E:86:06:32:29.
     *
     * Decoded E-WHEELS read:
     *   55 AA 03 20 61 EE 0C 81 FE
     * Wire bytes are every byte XOR 0x34:
     *   61 9E 37 14 55 DA 38 B5 CA
     *
     * ScooterIII max-speed register seen in the native app:
     *   F3, signed-short raw speed = km/h * 1000
     *
     * 30.0 km/h = 30000 = 0x7530 little endian 30 75
     * Decoded write:
     *   55 AA 04 20 03 F3 30 75 40 FE
     * Wire:
     *   61 9E 30 14 37 C7 04 41 74 CA
     */
    static final byte[] READ_EE_WIRE = hex("619E371455DA38B5CA");
    static final byte[] WRITE_30_WIRE = hex("619E301437C7044174CA");

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
    int initialF3 = -1;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);

        view = new TextView(this);
        view.setTextSize(15);
        view.setPadding(24, 40, 24, 24);
        setContentView(view);

        report = new File(getExternalFilesDir(null), "MOROBOT30_HCI_EXACT.txt");
        if (report.exists()) report.delete();

        String addr = getIntent().getStringExtra("addr");
        log("=== XBOT 30 HCI-EXACT ===");
        log("ADDR=" + addr);
        log("PROTO=ScooterIII/HB XOR=0x34");
        log("REGISTER=F3 TARGET_RAW=30000 TARGET=30.0 km/h");
        log("READ_EE_WIRE=" + toHex(READ_EE_WIRE));
        log("WRITE_30_WIRE=" + toHex(WRITE_30_WIRE));

        try {
            BluetoothAdapter a = BluetoothAdapter.getDefaultAdapter();
            if (a == null || !a.isEnabled()) { fail("Bluetooth unavailable/off; NOTHING WRITTEN"); return; }

            BluetoothDevice d = a.getRemoteDevice(addr);
            log("CONNECT");
            gatt = d.connectGatt(this, false, cb, BluetoothDevice.TRANSPORT_LE);

            h.postDelayed(new Runnable() {
                public void run() {
                    if (!done) fail("GLOBAL TIMEOUT; verification not completed");
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

            if (servicesReady) {
                log("SERVICES duplicate ignored");
                return;
            }
            servicesReady = true;

            BluetoothGattService s = g.getService(SVC);
            if (s == null) { fail("NUS SERVICE MISSING; NOTHING WRITTEN"); return; }

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
            if (c == null) { fail("CCCD MISSING; NOTHING WRITTEN"); return; }

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
                        log("PROBE REAL E-WHEELS EE BLOCK -> " + toHex(READ_EE_WIRE));
                        if (!writeNoResponse(READ_EE_WIRE))
                            fail("PROBE QUEUE FAILED; NOTHING WRITTEN");
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

        log("VALID EE BLOCK F3_RAW=" + raw + " SPEED=" + (raw / 1000.0f) + " km/h");

        if (raw < 5000 || raw > 60000) {
            fail("IMPLAUSIBLE F3 VALUE=" + raw + "; NOTHING WRITTEN");
            return;
        }

        if (!gotInitial) {
            gotInitial = true;
            initialF3 = raw;

            log("PROTOCOL VERIFIED FROM REAL HCI PATTERN");
            log("INITIAL F3=" + raw);

            if (raw == 30000) {
                success("ALREADY 30.0 km/h; no write needed");
                return;
            }

            h.postDelayed(new Runnable() {
                public void run() {
                    if (done) return;
                    wrote = true;
                    log("WRITE 30.0 -> " + toHex(WRITE_30_WIRE));
                    if (!writeNoResponse(WRITE_30_WIRE)) {
                        fail("WRITE QUEUE FAILED");
                        return;
                    }

                    h.postDelayed(new Runnable() {
                        public void run() {
                            if (done) return;
                            verifying = true;
                            log("VERIFY EE BLOCK -> " + toHex(READ_EE_WIRE));
                            if (!writeNoResponse(READ_EE_WIRE))
                                fail("VERIFY READ QUEUE FAILED");
                        }
                    }, 650);

                    h.postDelayed(new Runnable() {
                        public void run() {
                            if (!done && verifying)
                                fail("VERIFY TIMEOUT; no F3=30000 confirmation");
                        }
                    }, 3500);
                }
            }, 250);

            return;
        }

        if (wrote && verifying) {
            if (raw == 30000) {
                success("VERIFIED F3=30000");
            } else {
                log("VERIFY OBSERVED F3=" + raw + "; waiting for 30000");
            }
        }
    }

    boolean writeNoResponse(byte[] data) {
        if (gatt == null || rx == null) return false;

        int props = rx.getProperties();
        if ((props & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
            log("WARNING RX lacks WRITE_NO_RESPONSE; props=0x" +
                Integer.toHexString(props));
        }

        rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rx.setValue(data);

        boolean ok = gatt.writeCharacteristic(rx);
        log("QUEUE=" + ok + " WIRE=" + toHex(data) + " DEC=" + toHex(xor34(data)));
        return ok;
    }

    /*
     * E-WHEELS bulk response observed in HCI:
     *
     * 55 AA 0E 23 01 EE
     *   [EE lo hi]
     *   [EF lo hi]
     *   [F0 lo hi]
     *   [F1 lo hi]
     *   [F2 lo hi]
     *   [F3 lo hi]
     *   checksumLE
     *
     * Before captured change F3 was C8 32 = 13000.
     * Later it was 50 46 = 18000.
     */
    int parseEeBlockF3(byte[] d) {
        if (d.length < 20) return -1;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return -1;

        int total = u(d[2]) + 6;
        if (total > d.length || total < 20) return -1;
        if (!checksum55(d, total)) return -1;

        if (u(d[3]) != 0x23) return -1; // controller -> app
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
        log("FINAL: SUCCESS " + reason + " SPEED=30.0 km/h");
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
                public void run() { view.append(s + "\n"); }
            });
        }
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

echo '[1/5] aapt'
aapt package -f -M "$W/AndroidManifest.xml" -I "$ANDROID_RES" -F "$UNSIGNED" || exit 1

echo '[2/5] javac/ecj'
ecj -proc:none -d "$CLS" -bootclasspath "$ANDROID_CLASSES_JAR" "$SRC/MainActivity.java" || exit 1

echo '[3/5] d8'
d8 --min-api 23 --lib "$ANDROID_CLASSES_JAR" --output "$DEX" $(find "$CLS" -type f -name '*.class') || exit 1
(
  cd "$DEX" || exit 1
  aapt add -f "$UNSIGNED" classes.dex >/dev/null
) || exit 1

if command -v zipalign >/dev/null 2>&1; then
  zipalign -f 4 "$UNSIGNED" "$ALIGNED" || exit 1
else
  cp "$UNSIGNED" "$ALIGNED"
fi

if [ ! -f "$KEY" ]; then
  keytool -genkeypair -keystore "$KEY" \
    -storepass blckswan42 -keypass blckswan42 \
    -alias xbot30hci -keyalg RSA -keysize 2048 -validity 10000 \
    -dname 'CN=BLCKSWAN XBOT30 HCI,O=BLCKSWAN,C=NO' \
    >/dev/null 2>&1 || exit 1
fi

echo '[4/5] sign'
apksigner sign \
  --ks "$KEY" \
  --ks-key-alias xbot30hci \
  --ks-pass pass:blckswan42 \
  --key-pass pass:blckswan42 \
  --out "$SIGNED" "$ALIGNED" || exit 1

apksigner verify "$SIGNED" || exit 1

echo '[5/5] install + run'
su -c "cp '$SIGNED' '$REMOTE'; chmod 0644 '$REMOTE'; pm install -r '$REMOTE'" || {
  echo '[!] install -r feilet. Prøver clean install av bare denne hjelpeappen.'
  su -c "pm uninstall '$PKG' >/dev/null 2>&1 || true; pm install '$REMOTE'" || exit 1
}

for P in android.permission.ACCESS_FINE_LOCATION android.permission.BLUETOOTH_CONNECT android.permission.BLUETOOTH_SCAN; do
  su -c "pm grant '$PKG' '$P'" >/dev/null 2>&1 || true
done

# Bare én app skal eie GATT-linken.
su -c 'am force-stop com.HB.EWHEELS' >/dev/null 2>&1 || true
su -c 'am force-stop com.mini.xbot' >/dev/null 2>&1 || true
su -c 'am force-stop no.nordicsemi.android.mcp' >/dev/null 2>&1 || true
su -c 'am force-stop no.blckswan.xbot30real' >/dev/null 2>&1 || true

su -c "am force-stop '$PKG'; rm -f '$REPORT' '$OUT'" >/dev/null 2>&1 || true

su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR'" || exit 1

echo
echo 'Venter på ekte EE-read -> F3 write -> EE-verify ...'
for i in $(seq 1 22); do
  if su -c "test -s '$REPORT'" >/dev/null 2>&1; then
    if su -c "grep -q 'FINAL:' '$REPORT'" >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 1
done

echo
echo '=== RESULTAT ==='
if su -c "test -s '$REPORT'" >/dev/null 2>&1; then
  su -c "cp '$REPORT' '$OUT'; chmod 0644 '$OUT'; cat '$REPORT'"
else
  echo 'Ingen rapport. Relevant logcat:'
  su -c "logcat -d -v brief | grep -iE 'xbot30hci|BluetoothGatt' | tail -n 160" |
    tee "$HOME/MOROBOT30_HCI_EXACT.txt"
  cp "$HOME/MOROBOT30_HCI_EXACT.txt" "$OUT" 2>/dev/null || true
fi

echo
echo "Rapport: $OUT"
