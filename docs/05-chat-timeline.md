# Chat timeline / reconstructed technical transcript

This is a reconstructed technical transcript from the available conversation context, generated artifacts, and uploaded logs. It is **not** a byte-for-byte platform export.

The purpose is to preserve the reasoning path, failed hypotheses, user observations, generated scripts, and verified results in chronological order.

## 1. Goal

User wanted to control scooter maximum speed directly over BLE from rooted Android/Termux.

Target observed throughout the session:

`EC:6E:86:06:32:29`

Installed applications discussed:

- E-WHEELS
- XBOT
- MiniRobot
- nRF Connect

The user specifically suspected multiple riding modes later in the investigation: walking, eco, drive and sport.

## 2. Early protocol attempt

We initially worked from a suspected generic max-speed register around `0x74` / `0x7D`.

Candidate frames were built for multiple address/header variants, including `3D/20`, `3E/04`, and old `55AA`.

User ran the safe probe helper and returned a log showing:

```text
NUS OK RXprops=0xc TXprops=0x10
CCCD status=0
GATT WRITE status=0
...
FINAL: FAIL NO VALID 0x7D READ RESPONSE; NOTHING WRITTEN
```

Interpretation in chat:

The BLE layer was healthy, but the guessed application protocol was wrong. The helper's read-before-write gate prevented a blind speed change.

## 3. Static analysis

The installed E-WHEELS APK was extracted and decompiled. Native symbols exposed max-speed and Bluetooth packet logic.

Important symbols discussed in chat included:

```text
UserInterface::sliderEventMaxSpeed
UserInterface::NeedSetMaxSpeed
TriggerLogic::onTouchMaxSpeed
Bluetooth::SendFramePack
Bluetooth::SendWriteCmd2
Bluetooth::SendReadCmdWithAddr2
```

We found a generic `0x7D` path in native code, but its failure against the physical controller suggested a different model-specific branch.

There was also a temporary hypothesis about a keyed checksum derived from a six-digit value. This remained a static-analysis clue, but the later HCI capture gave a more direct explanation of the actual wire behavior used in the tested session.

## 4. HCI capture

A Termux/root helper was created to enable Bluetooth HCI capture and copy the resulting log.

The first helper looked for a conventional `btsnoop_hci.log`, but the user reported:

```text
Fant ingen btsnoop-fil.

total ...
-rw-rw-r-- ... 3.0M ... BT_HCI_2026_0814_015255_UTC+0200.cfa.curf
```

The capture path was therefore adjusted to the Motorola/MediaTek naming convention.

The resulting file was uploaded as `EWHEELS_HCI.cfa`.

## 5. Wire transform discovered

Analysis of the capture found real writes to the Nordic UART RX characteristic and notifications from TX.

A decisive example from chat:

```text
wire:
61 9E 37 14 55 DA 38 B5 CA

XOR 0x34:
55 AA 03 20 61 EE 0C 81 FE
```

This revealed the E-WHEELS wire obfuscation:

`decoded XOR 0x34`

This explained the earlier silent failures.

## 6. Correct active register found

The HCI-derived EE-block response showed `F3=18000`, interpreted as 18.0 km/h.

A real E-WHEELS write was identified, then a 30.0 km/h write was generated:

```text
decoded:
55 AA 04 20 03 F3 30 75 40 FE

wire:
61 9E 30 14 37 C7 04 41 74 CA
```

A new helper was built from the real HCI pattern.

User uploaded the resulting log:

```text
VALID EE BLOCK F3_RAW=18000 SPEED=18.0 km/h
PROTOCOL VERIFIED FROM REAL HCI PATTERN
INITIAL F3=18000
...
WRITE 30.0 -> 619E301437C7044174CA
...
VALID EE BLOCK F3_RAW=30000 SPEED=30.0 km/h
FINAL: SUCCESS VERIFIED F3=30000 SPEED=30.0 km/h
```

This was the first confirmed controller-level success.

## 7. Documentation moved to GitHub

User requested a good summary and GitHub upload.

A write-up was committed to:

`bspippi1337/restless`

under:

`docs/morobot-xbot-speed-reverse-engineering.md`

plus concise companion files.

Those files are copied verbatim into this bundle under:

`docs/restless-original/`

## 8. MoroSpeed tool

User requested `morospeed`.

A Termux installer/helper was generated to provide commands such as:

```text
morospeed read
morospeed 25
morospeed 30
morospeed 32
```

The tool used the verified NUS + XOR + F3 protocol and required readback confirmation.

## 9. User identifies multiple riding programs

User then said, in substance:

> I think there can be several places to set max speed. There are different programs: walking, eco, drive and sport.

This shifted the investigation from one global max-speed value toward a multi-profile model.

Native/HCI analysis produced:

```text
EE=225
EF=463
F0=515
F1=386
F2=0
F3=...
```

and the conversion:

`km/h ~= raw * EE / 5794.652832`

giving approximately:

```text
EF 463 ~= 18 km/h
F0 515 ~= 20 km/h
F1 386 ~= 15 km/h
```

Native code also produced the numeric mapping:

```text
7E=0 -> F0
7E=1 -> EF
7E=2 -> F1
7E=3 -> F3
```

We explicitly kept the human-facing label mapping as unproven.

## 10. ALL30 v1

User asked first for a variant that set 30 on all slots.

The generated ALL30 helper attempted:

- EF -> 30-equivalent
- F0 -> 30-equivalent
- F1 -> 30-equivalent
- F3 -> 30000

User's log showed:

```text
TARGET_SCALED_RAW=772 (~30.0 km/h)
...
VERIFY:
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
FINAL: FAIL VERIFY MISMATCH
```

So only F3 moved.

## 11. ALL30 v2

Next hypothesis: select the corresponding mode through `7E` before writing the profile slot.

The user returned:

```text
ORIGINAL MODE=0
SELECT MODE 0
WRITE SLOT reg=0xF0 raw=772
...
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
FINAL: FAIL F0 VERIFY FAILED got=515 expected=772
```

Conclusion:

Mode selection was not the missing permission layer.

## 12. ALL30 v3

Further native analysis suggested separate limits:

```text
C2 -> associated with EF
C4 -> associated with F0
C6 -> associated with F1
```

The controller reported:

```text
C2=463
C4=515
C6=386
```

These matched the factory profile speeds.

V3 tried to raise C2 to the 30 km/h-equivalent raw value:

```text
WRITE CAP 0xC2 raw=772
GATT WRITE status=0
...
CAPS C2=463 ...
ABORT: C2 CAP REJECTED got=463 expected=772
ROLLBACK: best effort
FINAL: FAIL ... rollback attempted
```

This moved the working theory one layer deeper: normal profile writes are bounded by controller-provided limits, and those limits themselves are not writable through the same ordinary command path.

## 13. XBOT split extraction

The first copied `XBOT_FULL.apk` turned out to be only `base.apk`, because the shell command used:

`pm path ... | head -n1`

The user then collected all installed split APKs.

The uploaded set contains:

```text
base.apk
split_config.arm64_v8a.apk
split_config.en.apk
split_config.nb.apk
split_config.xxhdpi.apk
```

The ARM64 split contains:

`lib/arm64-v8a/libcpp_empty_test.so`

This is the next primary reverse-engineering target for discovering factory/firmware/service command paths that may sit below C2/C4/C6.

## 14. Present state

Strongly verified:

- NUS transport
- XOR 0x34 wire transform
- ScooterIII/HB packet family
- EE block read
- F3 speed encoding
- F3=30000 write + controller readback
- multi-slot profile values
- numeric 7E mode-to-slot mapping
- C2/C4/C6 cap values
- ordinary C2 write rejection

Still open:

- UI names to 7E values
- privileged/factory cap write path
- firmware/OTA mechanisms
- whether cap values are writable at all without firmware modification
