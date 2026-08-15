# Verified ForcedUpgrade DK path

Status: **HTTP/file-routing layer verified; controller flash completion not yet proven.**

Snapshot: 2026-08-15.

## Why the strategy changed

Several ordinary controller-write ideas now have negative controller readback:

- per-profile cap writes (`C2/C4/C6`) are accepted by Android/GATT but do not persist,
- the XBOT global limiter experiment (`0x72=0` over HB) leaves `0x1D=0x07F9`, bit 0 still set,
- the wheel-factor experiment (`EE=226`) is accepted by Android/GATT but reads back as the original `EE=225`.

This puts the strongest current lead below the normal HB parameter layer: XBOT/Lebitec firmware update.

## Direct Android GATT breakthrough

A root `app_process` client initially failed because a naked process did not have Android's Bluetooth framework bootstrap. The working path is:

1. initialize `BluetoothFrameworkInitializer` / `BluetoothServiceManager`,
2. run the client as Android system UID 1000,
3. use the system context with attribution `uid=1000 package=android`,
4. connect with public `BluetoothGatt` APIs.

The working client reaches:

```text
CONNECTION status=0 state=2
SERVICES status=0
NUS OK
CCCD status=0
```

This provided controller readback for the `0x72` and `EE` rejection tests without installing an APK.

## `0x72` result: rejected

Target state before the write:

```text
0x1D = 0x07F9
bit0 = 1
```

The HB write sent:

```text
55 AA 04 20 03 72 00 00 66 FF
```

Wire form after XOR `0x34`:

```text
61 9E 30 14 37 46 34 34 52 CB
```

Android reported a successful GATT write, but controller readback remained:

```text
0x1D = 0x07F9
bit0 = 1
```

Conclusion: the direct `0x72` limiter-off command is not accepted by this controller configuration.

## `EE` result: rejected

Initial block:

```text
EE=225
EF=463
F0=515
F1=386
F2=0
F3=30000
```

A test write changed only `EE` from 225 to 226, then immediately read the block back. The controller still reported `EE=225`.

Conclusion: wheel-factor scaling is not a writable bypass through the ordinary HB write path.

## Vendor DK identity and files

The E-WHEELS/XBOT firmware logic uses controller map values to construct DK identities.

Observed target identity:

```text
DK_MODEL = 0x84A8
DK_ID    = 0x061007F9
```

The matching live E-WHEELS vendor image was recovered:

```text
DK061007f9.bin
size   = 28444 bytes
sha256 = 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

A nearby vendor image was also recovered:

```text
DK061007a7.bin
size   = 28380 bytes
sha256 = 919f76d8447044d58945dc491eeed324e6154f55c9cee7edce2d256410458595
```

The two images have very high entropy and are not simple near-identical plaintext firmware images. A naive binary speed-table patch is therefore not yet justified.

## E-WHEELS URL namespace correction

The installed E-WHEELS native library uses its own update namespace rather than only the generic `ScooterUpdata` namespace:

```text
http://www.lebitec.com/upload/Apps/EWHEELS/Config.xml
http://www.lebitec.com/upload/Apps/EWHEELS/DK%08x.bin
http://www.lebitec.com/upload/Apps/EWHEELS/DK/%08x/DK%04x.bin
```

The target's dynamic config key format resolves to:

```text
DK84a8061007f9
```

The current config does not expose that exact model-specific key, but the flat `DK061007f9.bin` exists and was downloaded successfully.

## ForcedUpgrade URL redirection

The XBOT ARM64 library also contains a separate privileged path:

```text
https://www.lebitec.com/upload/Apps/ForcedUpgrade/Scooter/%s/Config.xml
https://www.lebitec.com/upload/Apps/ForcedUpgrade/Scooter/%s/DK.bin
https://www.lebitec.com/upload/Apps/ForcedUpgrade/Scooter/%s/DK01.bin
```

An isolated native patch replaced only the ForcedUpgrade URLs with a local Termux HTTP server on `127.0.0.1:8765`.

Original ARM64 split SHA-256:

```text
1fe680898f86018c272775148b3a19267ef2371fb170691c38d5201e35bd3de5
```

Local-ForcedUpgrade patched split SHA-256:

```text
364e97b8b7a8ce3d8da98e99a46e6d61677a3edd28d18a1b628b2f237be80b20
```

Local test code:

```text
MORO42001
```

## Probe result: verified

Probe mode served only `Config.xml` and deliberately returned 404 for firmware binaries. XBOT requested:

```text
GET /f/MORO42001/Config.xml
GET /f/MORO42001/DK01.bin
```

This proved that the patched XBOT build was genuinely following the local ForcedUpgrade route and that this target branch specifically selects `DK01.bin`.

## Current-image routing result: verified

The local server was then switched to `current` mode and exposed the exact current vendor image as `DK01.bin`.

XBOT successfully fetched:

```text
GET /f/MORO42001/Config.xml  -> 200
GET /f/MORO42001/DK01.bin    -> 200
```

The server logged:

```text
bytes  = 28444
sha256 = 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

This is a major milestone: **the complete XBOT ForcedUpgrade HTTP/file-selection chain is verified against a controlled local source.**

What it does *not* yet prove is that the controller completed the flash/update protocol after XBOT downloaded the file.

## Current next step

Capture the BLE/HCI traffic during one current-image ForcedUpgrade cycle and identify the controller-side update sequence:

```text
enter update mode
-> metadata / command 7
-> DK chunks / command 8
-> ACK / retry behavior
-> footer or first-four-byte metadata / command 9
-> finish / command 10
```

The required proof is controller traffic and ACK progression, not only HTTP success or UI messages.

## Evidence rule

For this project:

- HTTP 200 proves XBOT downloaded a file.
- GATT status 0 proves Android queued/sent a write.
- Neither alone proves controller state changed.
- Controller readback, update ACKs, or equivalent independent evidence is required for controller-side success.
