# morosamt

Reverse-engineering notebook and evidence bundle for MOROBOT / XBOT / E-WHEELS BLE speed-control research.

This snapshot documents the path from failed generic BLE probes to a controller-verified 30.0 km/h write, then onward into the four-profile speed-limit model and the firmware-enforced caps that currently block EF/F0/F1 from being raised above their factory limits.

Snapshot date: 2026-08-14

## What is verified

- BLE transport: Nordic UART Service (NUS)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX/write: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX/notify: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Controller branch: ScooterIII / HB
- BLE payload transform: bytewise XOR `0x34`
- Active max-speed register on the confirmed branch: `F3`
- F3 encoding: uint16 little-endian, `raw = km/h * 1000`
- `F3=30000` was written and independently read back as `30.0 km/h`
- Profile-related values observed in the EE..F3 block:
  - `EF=463` ~= 18 km/h
  - `F0=515` ~= 20 km/h
  - `F1=386` ~= 15 km/h
  - `F3=30000` = 30 km/h
- Wheel/scaling register: `EE=225`
- Native-code-derived scaling for EF/F0/F1: approximately `km/h = raw * EE / 5794.652832`
- Native-code-derived mode/slot mapping:
  - `7E=0 -> F0`
  - `7E=1 -> EF`
  - `7E=2 -> F1`
  - `7E=3 -> F3`
- Per-profile upper-limit values observed:
  - `C2=463`
  - `C4=515`
  - `C6=386`
- Direct attempts to raise `C2` to the 30 km/h raw value were accepted by Android/GATT but rejected by the controller on readback.

## What is not yet proven

The human-facing names `Walking`, `Eco`, `Drive`, `Sport` have not yet been conclusively mapped to numeric `7E` values in this snapshot. The numeric mode-to-slot mapping is stronger than the UI-name mapping.

The mechanism below `C2/C4/C6` that enforces the factory caps is still under investigation. The full XBOT split installation, including the ARM64 native library, is included for the next stage of analysis.

## Important evidence rule

A successful Android `GATT WRITE status=0` is not treated as proof that a controller setting changed. A write is considered verified only when a subsequent controller readback returns the requested value.

## Layout

- `docs/` human-readable documentation
- `docs/restless-original/` copy of the earlier write-up that was committed to `bspippi1337/restless`
- `evidence/logs/` raw test logs
- `evidence/hci/` Bluetooth HCI capture
- `evidence/apks/` raw APK evidence
- `evidence/xbot-splits/` raw Android split APKs
- `evidence/native/` extracted native ARM64 library
- `reverse-engineering/asm/` focused disassemblies
- `reverse-engineering/full-disassembly/` large full disassemblies
- `tools/` generated test/helper scripts
- `MANIFEST.sha256` SHA-256 digest manifest

## Binary note

Binary files are stored as binary files. They are **not** base64 encoded.

The bundle contains third-party APK material and a raw HCI capture. If this repository is made public, review redistribution/privacy implications before committing every file.
