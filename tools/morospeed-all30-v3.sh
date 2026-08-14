#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# MoroSpeed ALL30 v3
#
# Fix after v2:
# The controller accepted F3=30000 but ignored EF/F0/F1=772.
# E-WHEELS native code shows EF/F0/F1 are bounded by per-profile
# maximum registers C2/C4/C6:
#
#   C2 -> max for EF
#   C4 -> max for F0
#   C6 -> max for F1
#
# On this controller the captured values are approximately:
#   C2=463 ~= 18 km/h
#   C4=515 ~= 20 km/h
#   C6=386 ~= 15 km/h
#
# So v3 first raises C2/C4/C6 to the raw 30 km/h value, verifies each,
# and ONLY THEN writes EF/F0/F1/F3. It verifies every stage.
#
# If a cap write is rejected, it stops and performs best-effort rollback.
# No reboot.

PKG="no.blckswan.morospeedall30v3"
ADDR="${MOROSPEED_ADDR:-EC:6E:86:06:32:29}"

W="$HOME/.morospeed-all30-v3-build"
SRC="$W/src/no/blckswan/morospeedall30v3"
CLS="$W/classes"
DEX="$W/dex"
KEY="$HOME/.morospeed-all30-v3-key.jks"
UNSIGNED="$W/u.apk"
ALIGNED="$W/a.apk"
SIGNED="$W/MoroSpeed-ALL30-v3.apk"
REMOTE="/data/local/tmp/MoroSpeed-ALL30-v3.apk"
REPORT_ANDROID="/sdcard/Android/data/$PKG/files/MOROSPEED_ALL30_V3.txt"
REPORT_OUT="/sdcard/Download/MOROSPEED_ALL30_V3.txt"

mkdir -p "$SRC" "$CLS" "$DEX"
rm -rf "$CLS" "$DEX"
mkdir -p "$CLS" "$DEX"
rm -f "$UNSIGNED" "$ALIGNED" "$SIGNED"

echo "=== MOROSPEED ALL30 v3 ==="
echo "Target: $ADDR"
echo "Raises C2/C4/C6 caps, then EF/F0/F1/F3, all with readback."
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
    <application android:label="MoroSpeed ALL30 v3" android:allowBackup="false">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
EOF

cat > "$SRC/MainActivity.java" <<'JAVA'
package no.blckswan.morospeedall30v3;

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

    // Real E-WHEELS reads, decoded packet XOR 0x34 on BLE wire.
    static final byte[] READ_MODE_WIRE = hex("619E3714554F3EC2CA");
    // decoded 55AA0320617B0AF6FE

    static final byte[] READ_CAP_WIRE  = hex("619E371455F61CA5CA");
    // decoded 55AA032061C22891FE -> read 40 bytes C2..D5

    static final byte[] READ_EE_WIRE   = hex("619E371455DA38B5CA");
    // decoded 55AA032061EE0C81FE -> read EE..F3

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
    boolean aborting = false;

    int state = 0;

    int originalMode = -1;
    int ee = -1;
    int targetScaled = -1;

    int origC2=-1, origC4=-1, origC6=-1;
    int origEF=-1, origF0=-1, origF1=-1, origF3=-1;

    int changedCaps = 0;
    int changedSlots = 0;

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);

        view = new TextView(this);
        view.setTextSize(15);
        view.setPadding(24, 40, 24, 24);
        setContentView(view);

        report = new File(getExternalFilesDir(null), "MOROSPEED_ALL30_V3.txt");
        if (report.exists()) report.delete();

        addr = getIntent().getStringExtra("addr");
        if (addr == null || addr.length() < 17)
            addr = "EC:6E:86:06:32:29";

        log("=== MOROSPEED ALL30 v3 ===");
        log("ADDR=" + addr);
        log("PROTO=ScooterIII/HB XOR=0x34");
        log("TARGET=30 km/h");
        log("PLAN caps C2/C4/C6 -> slots EF/F0/F1/F3");

        try {
            BluetoothAdapter a = BluetoothAdapter.getDefaultAdapter();
            if (a == null || !a.isEnabled()) {
                finishFail("Bluetooth unavailable/off; NOTHING WRITTEN");
                return;
            }

            BluetoothDevice d = a.getRemoteDevice(addr);
            log("CONNECT");
            gatt = d.connectGatt(this, false, cb, BluetoothDevice.TRANSPORT_LE);

            h.postDelayed(new Runnable() {
                @Override public void run() {
                    if (!done && !aborting)
                        abortWithRollback("GLOBAL TIMEOUT");
                }
            }, 45000);

        } catch (Throwable t) {
            finishFail("CONNECT EXCEPTION " + t + "; NOTHING WRITTEN");
        }
    }

    final BluetoothGattCallback cb = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            log("CONNECTION status=" + status + " state=" + newState);

            if (status == BluetoothGatt.GATT_SUCCESS &&
                newState == BluetoothProfile.STATE_CONNECTED) {
                log("CONNECTED; discoverServices=" + g.discoverServices());
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED && !done && !aborting) {
                finishFail("DISCONNECTED status=" + status);
            }
        }

        @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
            log("SERVICES status=" + status);

            if (status != BluetoothGatt.GATT_SUCCESS) {
                finishFail("SERVICE DISCOVERY " + status + "; NOTHING WRITTEN");
                return;
            }

            if (ready) return;
            ready = true;

            BluetoothGattService s = g.getService(SVC);
            if (s == null) {
                finishFail("NUS SERVICE MISSING; NOTHING WRITTEN");
                return;
            }

            rx = s.getCharacteristic(RX);
            tx = s.getCharacteristic(TX);

            if (rx == null || tx == null) {
                finishFail("NUS RX/TX MISSING; NOTHING WRITTEN");
                return;
            }

            log("NUS OK RXprops=0x" + Integer.toHexString(rx.getProperties()) +
                " TXprops=0x" + Integer.toHexString(tx.getProperties()));

            if (!g.setCharacteristicNotification(tx, true)) {
                finishFail("setCharacteristicNotification=false; NOTHING WRITTEN");
                return;
            }

            BluetoothGattDescriptor c = tx.getDescriptor(CCCD);
            if (c == null) {
                finishFail("CCCD MISSING; NOTHING WRITTEN");
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
                finishFail("CCCD STATUS " + status + "; NOTHING WRITTEN");
                return;
            }

            state = 1;
            delayedSend("READ ORIGINAL MODE", READ_MODE_WIRE, 250);
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

            if (aborting || done) return;

            int mode = parseModeBlock(dec);
            if (mode >= 0) {
                handleMode(mode);
                return;
            }

            int[] caps = parseCapBlock(dec);
            if (caps != null) {
                handleCaps(caps);
                return;
            }

            int[] slots = parseEeBlock(dec);
            if (slots != null) {
                handleSlots(slots);
            }
        }
    };

    synchronized void handleMode(int mode) {
        log("VALID MODE 7E=" + mode);

        if (state == 1) {
            if (mode < 0 || mode > 3) {
                finishFail("MODE OUT OF RANGE; NOTHING WRITTEN");
                return;
            }

            originalMode = mode;
            log("ORIGINAL MODE=" + originalMode);

            state = 2;
            delayedSend("READ C2..D5 CAPS", READ_CAP_WIRE, 250);
            return;
        }

        if (state == 40) {
            if (mode != originalMode) {
                abortWithRollback("MODE RESTORE VERIFY FAILED got=" + mode +
                                  " expected=" + originalMode);
                return;
            }

            log("ORIGINAL MODE RESTORED=" + mode);
            state = 41;
            delayedSend("FINAL READ CAPS", READ_CAP_WIRE, 250);
        }
    }

    synchronized void handleCaps(int[] c) {
        int c2=c[0], c3=c[1], c4=c[2], c5=c[3], c6=c[4], c7=c[5];

        log("CAPS C2=" + c2 + " C3=" + c3 +
            " C4=" + c4 + " C5=" + c5 +
            " C6=" + c6 + " C7=" + c7);

        if (state == 2) {
            if (!plausibleCapBlock(c)) {
                finishFail("CAP BLOCK SHAPE UNEXPECTED; NOTHING WRITTEN");
                return;
            }

            origC2 = c2;
            origC4 = c4;
            origC6 = c6;

            state = 3;
            delayedSend("READ INITIAL EE..F3", READ_EE_WIRE, 250);
            return;
        }

        if (state == 10) {
            if (c2 != targetScaled) {
                abortWithRollback("C2 CAP REJECTED got=" + c2 +
                                  " expected=" + targetScaled);
                return;
            }
            changedCaps |= 1;
            log("C2 CAP VERIFIED=" + c2);
            writeCap(0xC4, targetScaled, 11);
            return;
        }

        if (state == 11) {
            if (c4 != targetScaled) {
                abortWithRollback("C4 CAP REJECTED got=" + c4 +
                                  " expected=" + targetScaled);
                return;
            }
            changedCaps |= 2;
            log("C4 CAP VERIFIED=" + c4);
            writeCap(0xC6, targetScaled, 12);
            return;
        }

        if (state == 12) {
            if (c6 != targetScaled) {
                abortWithRollback("C6 CAP REJECTED got=" + c6 +
                                  " expected=" + targetScaled);
                return;
            }
            changedCaps |= 4;
            log("C6 CAP VERIFIED=" + c6);

            // Now the per-profile maxima allow 30 km/h.
            writeSlotWithMode(0, 0xF0, targetScaled, 20);
            return;
        }

        if (state == 41) {
            if (c2 != targetScaled || c4 != targetScaled || c6 != targetScaled) {
                abortWithRollback("FINAL CAP VERIFY MISMATCH C2=" + c2 +
                                  " C4=" + c4 + " C6=" + c6);
                return;
            }

            log("FINAL CAPS VERIFIED C2=C4=C6=" + targetScaled);
            state = 42;
            delayedSend("FINAL READ EE..F3", READ_EE_WIRE, 250);
        }
    }

    synchronized void handleSlots(int[] s) {
        int curEE=s[0], curEF=s[1], curF0=s[2],
            curF1=s[3], curF2=s[4], curF3=s[5];

        log("SLOTS EE=" + curEE +
            " EF=" + curEF +
            " F0=" + curF0 +
            " F1=" + curF1 +
            " F2=" + curF2 +
            " F3=" + curF3);

        if (state == 3) {
            if (curEE < 50 || curEE > 1000 ||
                curEF < 0 || curEF > 5000 ||
                curF0 < 0 || curF0 > 5000 ||
                curF1 < 0 || curF1 > 5000 ||
                curF3 < 1000 || curF3 > 65000) {
                finishFail("EE BLOCK SHAPE UNEXPECTED; NOTHING WRITTEN");
                return;
            }

            ee = curEE;
            origEF = curEF;
            origF0 = curF0;
            origF1 = curF1;
            origF3 = curF3;

            targetScaled = (int)((TARGET_KMH * SPEED_CONSTANT) / ee);

            if (targetScaled < 100 || targetScaled > 5000) {
                finishFail("TARGET RAW OUT OF RANGE; NOTHING WRITTEN");
                return;
            }

            log("PROTOCOL VERIFIED");
            log("WHEEL_EE=" + ee);
            log("ORIGINAL CAPS C2=" + origC2 +
                " C4=" + origC4 + " C6=" + origC6);
            log("ORIGINAL SLOTS EF=" + origEF +
                " F0=" + origF0 + " F1=" + origF1 +
                " F3=" + origF3);
            log("TARGET_SCALED_RAW=" + targetScaled +
                " (~" + one(kmhFromScaled(targetScaled, ee)) + " km/h)");
            log("TARGET_F3_RAW=" + TARGET_F3);

            // This is the actual v3 fix: raise profile caps first.
            writeCap(0xC2, targetScaled, 10);
            return;
        }

        if (state == 20) {
            if (curF0 != targetScaled) {
                abortWithRollback("F0 REJECTED got=" + curF0 +
                                  " expected=" + targetScaled);
                return;
            }
            changedSlots |= 1;
            log("F0 VERIFIED=" + curF0);
            writeSlotWithMode(1, 0xEF, targetScaled, 21);
            return;
        }

        if (state == 21) {
            if (curEF != targetScaled) {
                abortWithRollback("EF REJECTED got=" + curEF +
                                  " expected=" + targetScaled);
                return;
            }
            changedSlots |= 2;
            log("EF VERIFIED=" + curEF);
            writeSlotWithMode(2, 0xF1, targetScaled, 22);
            return;
        }

        if (state == 22) {
            if (curF1 != targetScaled) {
                abortWithRollback("F1 REJECTED got=" + curF1 +
                                  " expected=" + targetScaled);
                return;
            }
            changedSlots |= 4;
            log("F1 VERIFIED=" + curF1);
            writeSlotWithMode(3, 0xF3, TARGET_F3, 23);
            return;
        }

        if (state == 23) {
            if (curF3 != TARGET_F3) {
                abortWithRollback("F3 REJECTED got=" + curF3 +
                                  " expected=" + TARGET_F3);
                return;
            }
            changedSlots |= 8;
            log("F3 VERIFIED=" + curF3);

            state = 40;
            final byte[] restore = buildWrite(0x7E, originalMode);

            h.postDelayed(new Runnable() {
                @Override public void run() {
                    log("RESTORE ORIGINAL MODE=" + originalMode);
                    send(restore);

                    h.postDelayed(new Runnable() {
                        @Override public void run() {
                            log("VERIFY RESTORED MODE");
                            send(READ_MODE_WIRE);
                        }
                    }, 500);
                }
            }, 250);
            return;
        }

        if (state == 42) {
            boolean ok =
                curEF == targetScaled &&
                curF0 == targetScaled &&
                curF1 == targetScaled &&
                curF3 == TARGET_F3;

            log("FINAL SPEEDS EF=" + one(kmhFromScaled(curEF, ee)) +
                " F0=" + one(kmhFromScaled(curF0, ee)) +
                " F1=" + one(kmhFromScaled(curF1, ee)) +
                " F3=" + one(curF3 / 1000.0));

            if (ok) {
                success("ALL30 VERIFIED CAPS+SLOTS+MODE " +
                        "C2=C4=C6=" + targetScaled +
                        " EF=F0=F1=" + targetScaled +
                        " F3=" + curF3 +
                        " MODE=" + originalMode);
            } else {
                abortWithRollback("FINAL SLOT VERIFY MISMATCH " +
                    "EF=" + curEF + "/" + targetScaled + " " +
                    "F0=" + curF0 + "/" + targetScaled + " " +
                    "F1=" + curF1 + "/" + targetScaled + " " +
                    "F3=" + curF3 + "/" + TARGET_F3);
            }
        }
    }

    void writeCap(final int reg, final int raw, final int verifyState) {
        final byte[] w = buildWrite(reg, raw);

        log("WRITE CAP 0x" + hx(reg) +
            " raw=" + raw +
            " DEC=" + toHex(xor34(w)));

        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done || aborting) return;

                send(w);

                h.postDelayed(new Runnable() {
                    @Override public void run() {
                        if (done || aborting) return;
                        state = verifyState;
                        log("VERIFY CAP 0x" + hx(reg));
                        send(READ_CAP_WIRE);
                    }
                }, 650);
            }
        }, 250);
    }

    void writeSlotWithMode(final int mode,
                           final int reg,
                           final int raw,
                           final int verifyState) {
        final byte[] modeFrame = buildWrite(0x7E, mode);
        final byte[] slotFrame = buildWrite(reg, raw);

        log("SELECT MODE " + mode +
            " THEN SLOT 0x" + hx(reg) +
            " raw=" + raw);

        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done || aborting) return;

                send(modeFrame);

                h.postDelayed(new Runnable() {
                    @Override public void run() {
                        if (done || aborting) return;

                        log("WRITE SLOT 0x" + hx(reg) +
                            " DEC=" + toHex(xor34(slotFrame)));
                        send(slotFrame);

                        h.postDelayed(new Runnable() {
                            @Override public void run() {
                                if (done || aborting) return;
                                state = verifyState;
                                log("VERIFY SLOT 0x" + hx(reg));
                                send(READ_EE_WIRE);
                            }
                        }, 650);
                    }
                }, 500);
            }
        }, 250);
    }

    void delayedSend(final String label, final byte[] data, long delay) {
        h.postDelayed(new Runnable() {
            @Override public void run() {
                if (done || aborting) return;
                log(label);
                send(data);
            }
        }, delay);
    }

    boolean send(byte[] data) {
        if (done || gatt == null || rx == null) return false;

        rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rx.setValue(data);

        boolean ok = gatt.writeCharacteristic(rx);

        log("QUEUE=" + ok +
            " WIRE=" + toHex(data) +
            " DEC=" + toHex(xor34(data)));

        if (!ok && !aborting)
            abortWithRollback("GATT QUEUE FAILED");

        return ok;
    }

    void abortWithRollback(final String reason) {
        if (done || aborting) return;
        aborting = true;

        log("ABORT: " + reason);
        log("ROLLBACK: best effort");

        long d = 150;

        // Restore slots first while raised caps may still be present.
        if (origF0 >= 0 && (changedSlots & 1) != 0) {
            scheduleRollback("F0", 0xF0, origF0, d); d += 350;
        }
        if (origEF >= 0 && (changedSlots & 2) != 0) {
            scheduleRollback("EF", 0xEF, origEF, d); d += 350;
        }
        if (origF1 >= 0 && (changedSlots & 4) != 0) {
            scheduleRollback("F1", 0xF1, origF1, d); d += 350;
        }
        if (origF3 >= 0 && (changedSlots & 8) != 0) {
            scheduleRollback("F3", 0xF3, origF3, d); d += 350;
        }

        if (origC2 >= 0 && (changedCaps & 1) != 0) {
            scheduleRollback("C2", 0xC2, origC2, d); d += 350;
        }
        if (origC4 >= 0 && (changedCaps & 2) != 0) {
            scheduleRollback("C4", 0xC4, origC4, d); d += 350;
        }
        if (origC6 >= 0 && (changedCaps & 4) != 0) {
            scheduleRollback("C6", 0xC6, origC6, d); d += 350;
        }

        if (originalMode >= 0) {
            final byte[] m = buildWrite(0x7E, originalMode);
            final long md = d;
            h.postDelayed(new Runnable() {
                @Override public void run() {
                    log("ROLLBACK MODE=" + originalMode);
                    send(m);
                }
            }, md);
            d += 400;
        }

        final long finishDelay = d + 350;
        h.postDelayed(new Runnable() {
            @Override public void run() {
                finishFail("ABORTED: " + reason + " ; rollback attempted");
            }
        }, finishDelay);
    }

    void scheduleRollback(final String name,
                          final int reg,
                          final int raw,
                          long delay) {
        final byte[] w = buildWrite(reg, raw);
        h.postDelayed(new Runnable() {
            @Override public void run() {
                log("ROLLBACK " + name + "=" + raw);
                send(w);
            }
        }, delay);
    }

    static byte[] buildWrite(int reg, int raw) {
        byte[] d = new byte[10];

        d[0]=(byte)0x55;
        d[1]=(byte)0xAA;
        d[2]=(byte)0x04;
        d[3]=(byte)0x20;
        d[4]=(byte)0x03;
        d[5]=(byte)reg;
        d[6]=(byte)(raw & 0xFF);
        d[7]=(byte)((raw >>> 8) & 0xFF);

        int sum=0;
        for (int i=2; i<=7; i++)
            sum=(sum + (d[i] & 0xFF)) & 0xFFFF;

        int chk=(0xFFFF - sum) & 0xFFFF;
        d[8]=(byte)(chk & 0xFF);
        d[9]=(byte)((chk >>> 8) & 0xFF);

        return xor34(d);
    }

    // C2 response contains 40 bytes = C2..D5, each register uint16 LE.
    int[] parseCapBlock(byte[] d) {
        if (d.length < 48) return null;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return null;

        int total=u(d[2]) + 6;
        if (total > d.length || total < 48) return null;
        if (!checksum55(d,total)) return null;

        if (u(d[3]) != 0x23 ||
            u(d[4]) != 0x01 ||
            u(d[5]) != 0xC2) return null;

        int[] out=new int[20];
        for (int i=0; i<20; i++) {
            int p=6 + i*2;
            out[i]=u(d[p]) | (u(d[p+1]) << 8);
        }
        return out;
    }

    boolean plausibleCapBlock(int[] c) {
        if (c == null || c.length < 6) return false;

        int c2=c[0], c3=c[1], c4=c[2], c5=c[3], c6=c[4], c7=c[5];

        return c2 > 0 && c2 < 5000 &&
               c4 > 0 && c4 < 5000 &&
               c6 > 0 && c6 < 5000 &&
               c3 >= 0 && c3 < c2 &&
               c5 >= 0 && c5 < c4 &&
               c7 >= 0 && c7 < c6;
    }

    int parseModeBlock(byte[] d) {
        if (d.length < 18) return -1;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return -1;

        int total=u(d[2]) + 6;
        if (total > d.length || total < 18) return -1;
        if (!checksum55(d,total)) return -1;

        if (u(d[3]) != 0x23 ||
            u(d[4]) != 0x01 ||
            u(d[5]) != 0x7B) return -1;

        // start 7B, each register 16-bit:
        // 7B @6, 7C @8, 7D @10, 7E @12, 7F @14
        return u(d[12]) | (u(d[13]) << 8);
    }

    // Returns EE,EF,F0,F1,F2,F3.
    int[] parseEeBlock(byte[] d) {
        if (d.length < 20) return null;
        if (u(d[0]) != 0x55 || u(d[1]) != 0xAA) return null;

        int total=u(d[2]) + 6;
        if (total > d.length || total < 20) return null;
        if (!checksum55(d,total)) return null;

        if (u(d[3]) != 0x23 ||
            u(d[4]) != 0x01 ||
            u(d[5]) != 0xEE) return null;

        int[] out=new int[6];
        out[0]=u(d[6])  | (u(d[7])  << 8);
        out[1]=u(d[8])  | (u(d[9])  << 8);
        out[2]=u(d[10]) | (u(d[11]) << 8);
        out[3]=u(d[12]) | (u(d[13]) << 8);
        out[4]=u(d[14]) | (u(d[15]) << 8);
        out[5]=u(d[16]) | (u(d[17]) << 8);
        return out;
    }

    boolean checksum55(byte[] d, int total) {
        int sum=0;
        for (int i=2; i<total-2; i++)
            sum=(sum + u(d[i])) & 0xFFFF;

        int want=(0xFFFF - sum) & 0xFFFF;
        int got=u(d[total-2]) | (u(d[total-1]) << 8);
        return want == got;
    }

    static double kmhFromScaled(int raw, int ee) {
        return raw * ((double)ee / SPEED_CONSTANT);
    }

    static String one(double v) {
        long x=Math.round(v * 10.0);
        return (x/10) + "." + Math.abs(x%10);
    }

    static String hx(int v) {
        return String.format("%02X", v & 0xFF);
    }

    void success(String reason) {
        if (done) return;
        done=true;
        log("FINAL: SUCCESS " + reason);
        closeLater();
    }

    void finishFail(String reason) {
        if (done) return;
        done=true;
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
        String line=System.currentTimeMillis() + " " + s + "\n";

        try {
            FileOutputStream f=new FileOutputStream(report,true);
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
        byte[] out=new byte[in.length];
        for (int i=0; i<in.length; i++)
            out[i]=(byte)((in[i] & 0xFF) ^ 0x34);
        return out;
    }

    static byte[] hex(String s) {
        byte[] b=new byte[s.length()/2];
        for (int i=0; i<s.length(); i+=2)
            b[i/2]=(byte)Integer.parseInt(s.substring(i,i+2),16);
        return b;
    }

    static String toHex(byte[] b) {
        StringBuilder s=new StringBuilder();
        for (byte x:b)
            s.append(String.format("%02X",x & 0xFF));
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
    -alias morospeedall30v3 \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname 'CN=MoroSpeed ALL30 v3,O=BLCKSWAN,C=NO' \
    >/dev/null 2>&1
fi

echo "[4/5] sign"
apksigner sign \
  --ks "$KEY" \
  --ks-key-alias morospeedall30v3 \
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
  no.blckswan.morospeedall30 \
  no.blckswan.morospeedall30v2
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
echo "[+] Starter ALL30 v3 mot $ADDR ..."
su -c "am start -W -n '$PKG/.MainActivity' --es addr '$ADDR'" >/dev/null

for i in $(seq 1 55); do
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
    echo "=== ALL30 v3 VERIFIED ==="
    exit 0
  fi

  exit 2
fi

echo "Ingen rapport fra ALL30 v3-hjelpeappen."
exit 3
