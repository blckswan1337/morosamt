# morosamt

Reverse-engineering notebook for MOROBOT / XBOT / E-WHEELS BLE speed-control and firmware-update research.

Snapshot status: **2026-08-15**, updated through verified XBOT ForcedUpgrade HTTP/file routing with the target's current DK image.

## What is verified

- BLE transport: Nordic UART Service (NUS)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX/write: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX/notify: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Controller branch: ScooterIII / HB
- BLE payload transform: bytewise XOR `0x34`
- `F3` uses direct uint16 little-endian encoding in units of `0.001 km/h`
- `F3=30000` was written and independently read back as `30.0 km/h`
- Profile block observed:
  - `EE=225`
  - `EF=463` ~= 18 km/h
  - `F0=515` ~= 20 km/h
  - `F1=386` ~= 15 km/h
  - `F2=0`
  - `F3=30000`
- E-WHEELS/XBOT scaling for EF/F0/F1 is approximately `km/h = raw * EE / 5794.652832`
- Numeric mode/slot mapping:
  - `7E=0 -> F0`
  - `7E=1 -> EF`
  - `7E=2 -> F1`
  - `7E=3 -> F3`
- Per-profile maxima are consumed from `C2`, `C4`, and `C6`.
- Direct attempts to raise profile slots or `C2` above their controller maxima are rejected/ignored on readback.
- Direct HB `0x72=0` limiter-off is rejected: `0x1D` remains `0x07F9`, bit 0 set.
- Direct `EE=226` wheel-factor test is rejected: controller reads back `EE=225`.
- A root `app_process` BluetoothGatt client works without APK installation when Android Bluetooth framework bootstrap is recreated and the process runs as system UID 1000.

## XBOT / firmware update findings

The complete installed XBOT split set was recovered, including `split_config.arm64_v8a.apk` and `lib/arm64-v8a/libcpp_empty_test.so`.

Static analysis found:

- a real firmware-update engine in `Bluetooth::UpdateApp()` / `Bluetooth::UpdataWrite()`
- forced-upgrade paths under `ForcedUpgrade/Scooter/...`
- normal E-WHEELS / Lebitec update paths
- firmware families including `DK`, `XK`, and `BP`
- a `PoJie` integer parsed from forced-upgrade `Config.xml`

`PoJie` remains an unverified lead. A native patch forcing `PoJie=1` did not produce a demonstrated controller-side speed bypass.

## Target DK identity

The target resolves to:

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

The images are high-entropy and not a simple near-identical plaintext pair, so blind binary patching is not currently justified.

## ForcedUpgrade breakthrough

An isolated XBOT native patch redirects only the ForcedUpgrade URLs to a local Termux HTTP server.

Test code:

```text
MORO42001
```

Probe mode deliberately withheld firmware binaries. XBOT successfully fetched local `Config.xml` and then requested:

```text
/f/MORO42001/DK01.bin
```

This proved that the real XBOT ForcedUpgrade path was following the controlled local source and that this branch selects `DK01.bin`.

The server was then switched to current-image mode. XBOT successfully downloaded the exact current vendor image as `DK01.bin`:

```text
HTTP 200
28444 bytes
sha256 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

This verifies the **complete HTTP/file-selection side of ForcedUpgrade**.

It does not yet prove that the controller completed the firmware flash. The next proof target is the BLE/HCI update transaction and ACK state machine.

See `docs/09-forced-update-dk.md`.

## Current conclusion

The normal writable HB register layer is no longer the primary path for unlocking the protected profile ceilings. `C2/C4/C6`, `0x72`, and `EE` have all failed controller readback tests, while the separate ForcedUpgrade path is now experimentally reachable and controllable.

Highest-value next work:

1. capture full HCI/ACL during one current-image ForcedUpgrade cycle,
2. reconstruct the controller update-mode command and ACK progression,
3. prove the current DK image completes controller-side update mode,
4. then test only a compatible alternate vendor DK or minimally modified image,
5. retain a from-scratch controller firmware as a fallback rather than the immediate next step.

## Evidence rule

`GATT WRITE status=0` is never treated as proof that a controller setting changed. HTTP `200` is never treated as proof that firmware was flashed. Controller readback or update ACK progression is required.

## Layout

- `docs/` human-readable documentation
- `docs/restless-original/` earlier write-up copied from `bspippi1337/restless`
- `tools/` generated helpers
- `MANIFEST.sha256` digest manifest for the larger evidence bundle
