# Experiment ledger

This file separates verified observations from hypotheses and rejected hypotheses.

## Experiment A: 0x7D generic probe

Status: **rejected for this controller path**

Observed:

- BLE connection: success
- NUS discovery: success
- CCCD enable: success
- GATT writes: status 0
- valid `0x7D` response: none
- permanent write: none

Interpretation: BLE transport was valid, but the assumed generic controller branch was wrong.

## Experiment B: HCI-derived F3=30

Status: **verified**

Initial controller value:

`F3=18000` -> 18.0 km/h

Write:

`F3=30000`

Readback:

`F3=30000` -> 30.0 km/h

Conclusion: 30 km/h is demonstrably possible on at least the F3 branch without replacing controller firmware.

## Experiment C: ALL30 v1

Status: **partially successful, hypothesis incomplete**

Attempted to set EF/F0/F1/F3 to 30 km/h equivalents.

Target scaled raw for EF/F0/F1: `772`.

Result:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
```

Conclusion: only F3 changed. EF/F0/F1 writes were ignored.

## Experiment D: ALL30 v2, select mode first

Status: **rejected as sufficient explanation**

Original mode: `7E=0`.

The script explicitly selected mode 0 and wrote `F0=772`.

Readback: `F0=515`.

Conclusion: selecting the corresponding mode was not enough.

## Experiment E: ALL30 v3, raise cap first

Status: **controller cap write rejected**

Observed:

```text
C2=463 C3=154 C4=515 C5=154 C6=386 C7=154
```

Attempted: `C2=772`.

Android/GATT: `status=0`.

Controller readback: `C2=463`.

Conclusion: C2/C4/C6 are not ordinary writable user parameters through the same command path.

## Experiment F: XBOT PoJie native patch

Status: **no-go / not a verified bypass**

Static findings:

- `PoJie` string exists in XBOT native code.
- forced-upgrade `Config.xml` parser reads it as an integer.
- value is stored at `UserInterface+0x1BAC`.
- reset/init code clears the same field.
- no direct read/consumer of `+0x1BAC` has been proven in the analyzed ARM64 binary.

Patch hypothesis forced `PoJie=1` and raised the app-visible maximum to 30 km/h.

Practical result: no demonstrated controller-side bypass.

## Experiment G: direct `0x72` limiter-off over HB

Status: **rejected by controller readback**

Initial state:

```text
0x1D = 0x07F9
bit0 = 1
```

Decoded write:

```text
55 AA 04 20 03 72 00 00 66 FF
```

Android/GATT returned status 0.

Verification readback:

```text
0x1D = 0x07F9
bit0 = 1
```

Conclusion: using the correct HB transport does not make `0x72=0` disable the limiter on this target.

## Experiment H: direct EE wheel-factor write

Status: **rejected by controller readback**

Initial block:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
```

Test write: `EE=226`.

Android/GATT returned status 0.

Verification readback:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
```

Conclusion: EE is not writable through the ordinary HB path for this target. The earlier PackageManager-blocked test is superseded by this direct root `app_process` result.

## Experiment I: root `app_process` BluetoothGatt client

Status: **verified**

A naked root `app_process` initially returned a null `BluetoothAdapter` or timed out.

The working bootstrap:

1. initializes `BluetoothFrameworkInitializer` / `BluetoothServiceManager`,
2. runs as Android system UID 1000,
3. obtains attribution `uid=1000 package=android`,
4. connects through `BluetoothGatt`, discovers NUS, enables CCCD, and exchanges controller frames.

This is now the preferred direct BLE probe mechanism when APK installation is undesirable.

## Experiment J: recover target E-WHEELS DK image

Status: **verified**

Target identity:

```text
DK_MODEL = 84a8
DK_ID    = 061007f9
```

Recovered current vendor image:

```text
DK061007f9.bin
28444 bytes
sha256 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

Recovered nearby image:

```text
DK061007a7.bin
28380 bytes
sha256 919f76d8447044d58945dc491eeed324e6154f55c9cee7edce2d256410458595
```

The pair is high-entropy and differs extensively; it is not a simple plaintext speed-table diff.

## Experiment K: local ForcedUpgrade probe

Status: **verified**

Only XBOT's ForcedUpgrade URL strings were redirected to a local Termux HTTP server.

Test code: `MORO42001`.

Probe mode served `Config.xml` but deliberately withheld binaries.

Observed requests:

```text
GET /f/MORO42001/Config.xml -> 200
GET /f/MORO42001/DK01.bin   -> intentional 404
```

Conclusion: the real XBOT ForcedUpgrade path follows the controlled local source, and this controller/update branch selects `DK01.bin`.

## Experiment L: current vendor DK delivered through ForcedUpgrade

Status: **HTTP/file-selection layer verified; controller flash completion not yet proven**

The local server exposed the exact current `DK061007f9.bin` as `DK01.bin`.

Observed:

```text
GET /f/MORO42001/Config.xml -> 200
GET /f/MORO42001/DK01.bin   -> 200
```

Served payload:

```text
28444 bytes
sha256 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

Conclusion: XBOT can be made to fetch a controlled DK payload through its genuine ForcedUpgrade code path.

What remains unknown is whether the controller entered update mode and completed the DK chunk/ACK/finish sequence.

## Current working hypothesis

The ordinary consumer parameter path is constrained by controller-side policy. `C2/C4/C6`, `0x72`, and `EE` are all rejected on controller readback, while F3 remains independently writable to 30 km/h.

The strongest current path is therefore the privileged XBOT/Lebitec ForcedUpgrade layer.

Next experiment: capture full HCI/ACL during one current-image ForcedUpgrade cycle and reconstruct the update command/ACK state machine before testing an alternate or modified DK image.
