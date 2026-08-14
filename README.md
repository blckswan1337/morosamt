# morosamt

Reverse-engineering notebook for MOROBOT / XBOT / E-WHEELS BLE speed-control research.

Snapshot status: 2026-08-14, updated through the first XBOT native PoJie patch test.

## What is verified

- BLE transport: Nordic UART Service (NUS)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX/write: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX/notify: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Controller branch: ScooterIII / HB
- BLE payload transform: bytewise XOR `0x34`
- `F3` uses direct uint16 little-endian encoding in units of `0.001 km/h`
- `F3=30000` was written and independently read back as `30.0 km/h`
- Profile values observed in the `EE..F3` block:
  - `EE=225`
  - `EF=463` ~= 18 km/h
  - `F0=515` ~= 20 km/h
  - `F1=386` ~= 15 km/h
  - `F3=30000` = 30 km/h after the verified write
- E-WHEELS/XBOT native scaling for EF/F0/F1 is approximately `km/h = raw * EE / 5794.652832`
- Numeric mode/slot mapping from native code:
  - `7E=0 -> F0`
  - `7E=1 -> EF`
  - `7E=2 -> F1`
  - `7E=3 -> F3`
- Per-profile maxima are read from:
  - `C2` for the EF branch
  - `C4` for the F0 branch
  - `C6` for the F1 branch
- Controller values were `C2=463`, `C4=515`, `C6=386`.
- Direct attempts to raise profile slots above those maxima were ignored by the controller.
- Direct attempt to raise `C2` to the 30 km/h-equivalent raw value was accepted by Android/GATT but rejected on controller readback.

## XBOT native analysis update

The complete installed XBOT split set was recovered, including `split_config.arm64_v8a.apk` and `lib/arm64-v8a/libcpp_empty_test.so`.

Static analysis found:

- a real firmware-update engine in `Bluetooth::UpdateApp()` / `Bluetooth::UpdataWrite()`
- forced-upgrade paths under `ForcedUpgrade/Scooter/...`
- normal update paths under `ScooterUpdata/...`
- firmware families including `DK`, `XK`, and `BP`
- a `PoJie` integer parsed from the forced-upgrade `Config.xml`

`PoJie` is stored in `UserInterface` at offset `0x1BAC`. However, in the analyzed ARM64 build the field has so far only been found initialized/reset and written by the XML parser. No direct consumer/read of the field has yet been proven. This makes `PoJie` an interesting lead, but not a verified speed-unlock switch.

A native XBOT patch was produced that forced `PoJie=1` and patched the app-visible maximum to 30 km/h. Initial practical result: **no-go so far**. The patch did not yet produce a demonstrated controller-side bypass of the `C2/C4/C6` limits.

## Strong external clue

Independent public reverse-engineering reports describe using Lebitec/XBOT's **ForcedUpgrade** path to unlock an MCU for firmware access and to redirect an XBOT forced-upgrade download to another Lebitec firmware image. This strongly supports the firmware/update path as a real privileged layer below ordinary parameter writes.

It does **not** prove that a completely new firmware is necessary for this controller. The current evidence instead favors finding or adapting the correct existing Lebitec firmware/config/update path before attempting a from-scratch firmware rewrite.

## Current conclusion

A full custom firmware is **not the preferred next step**.

30 km/h is already controller-verified through `F3`. The unresolved problem is raising the other profile ceilings. The highest-value next work is:

1. identify the exact controller/update family (`DK`, `XK`, `BP`, etc.),
2. recover the matching forced-upgrade `Config.xml` / firmware image,
3. map the cap values inside that configuration/firmware,
4. determine whether an existing unlocked Lebitec image or parameter blob can provide 30 km/h,
5. only consider a custom firmware rewrite if the controller image proves to contain hardcoded limits with no usable existing update/config path.

## Evidence rule

`GATT WRITE status=0` is never treated as proof that a controller setting changed. Success requires controller readback or equivalent independent verification.

## Layout

- `docs/` human-readable documentation
- `docs/restless-original/` earlier write-up copied from `bspippi1337/restless`
- `tools/` generated helpers
- `MANIFEST.sha256` digest manifest for the larger evidence bundle
