# Current state and next steps

Snapshot: 2026-08-15.

## Proven

1. Correct BLE service and characteristics.
2. Wire-level XOR `0x34` transform.
3. ScooterIII/HB protocol family.
4. F3 direct encoding and successful 30 km/h write/readback.
5. EE scaling used by EF/F0/F1.
6. Numeric mode selector `7E` and slot mapping.
7. `C2/C4/C6` are the maxima consumed by `GetSpeedMaxAndMinVal()` for the three scaled profile branches.
8. Normal writes to EF/F0/F1 above those maxima are rejected/ignored by controller behavior.
9. A normal write to `C2` itself is rejected by controller readback.
10. XBOT contains a real firmware/forced-upgrade engine with `UpdateApp`, `UpdataWrite`, `OnTouchUpdate`, `ForcedUpgrade/Scooter/...`, and DK/XK/BP-family images.
11. XBOT parses `PoJie` from forced-upgrade `Config.xml`, but no proven speed-limit consumer of that field has been found.
12. The PoJie/app-max native patch did not demonstrate a controller-side bypass.
13. XBOT contains a global limiter callback using register `0x72` and state bit 0 of register `0x1D`.
14. The target reports `0x1D=0x07F9`, bit 0 set.
15. Direct ScooterIII/HB `0x72=0` was accepted by Android/GATT but controller readback remained `0x1D=0x07F9`. The limiter command is therefore rejected for this target.
16. `EE=225` was directly tested for writability by attempting `EE=226`; controller readback remained `EE=225`. The wheel-factor bypass is rejected through the ordinary HB write path.
17. A root `app_process` BluetoothGatt client works when Android Bluetooth framework bootstrap is recreated and the process runs as system UID 1000.
18. The target's vendor DK identity is `DK_MODEL=0x84A8`, `DK_ID=0x061007F9`.
19. Live E-WHEELS vendor firmware `DK061007f9.bin` was recovered, 28444 bytes, SHA-256 `856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62`.
20. A nearby image `DK061007a7.bin` was also recovered, 28380 bytes, SHA-256 `919f76d8447044d58945dc491eeed324e6154f55c9cee7edce2d256410458595`.
21. XBOT ForcedUpgrade URLs were redirected to a local Termux HTTP server with an isolated native string patch.
22. Probe mode proved that XBOT requests `Config.xml` and then specifically `DK01.bin` for the test code `MORO42001`.
23. Current mode proved that XBOT downloads the complete controlled `DK01.bin` payload: HTTP 200, 28444 bytes, SHA-256 matching the recovered current vendor image.

## Register-write conclusion

The useful ordinary-write experiments now form a consistent pattern:

```text
C2/C4/C6 / profile ceilings -> rejected or ignored
0x72 limiter state          -> rejected
EE wheel factor             -> rejected
F3=30000                    -> accepted and read back
```

This strongly suggests that the protected profile limits are not exposed as freely writable HB configuration on this controller.

`GATT WRITE status=0` is not treated as proof of a successful setting change. Controller readback is decisive.

## PoJie status

`PoJie` remains an unverified forced-upgrade/config field rather than a proven runtime speed-unlock switch.

The analyzed ARM64 build shows the field being initialized/reset and populated from XML, but no direct speed-limit consumer has been proven. The practical patch that forced `PoJie=1` did not produce a verified controller-side bypass.

## Global `0x72` status

Closed as a direct bypass.

The direct HB command requested limiter off, Android reported successful transmission, and controller readback still showed `0x1D=0x07F9`, bit 0 set.

See `docs/08-limit72-hb.md`.

## EE status

Closed as an ordinary writable bypass.

Initial controller state:

```text
EE=225
EF=463
F0=515
F1=386
F2=0
F3=30000
```

After writing `EE=226`, the next controller read returned the same original block with `EE=225`.

## Firmware identity

The E-WHEELS native updater uses its own namespace:

```text
Apps/EWHEELS/Config.xml
Apps/EWHEELS/DK%08x.bin
Apps/EWHEELS/DK/%08x/DK%04x.bin
```

Target identity:

```text
DK_MODEL = 84a8
DK_ID    = 061007f9
```

Current vendor image:

```text
DK061007f9.bin
28444 bytes
sha256 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

The nearby `061007a7` image is not a simple plaintext near-match. Both images are high-entropy and differ extensively, so direct blind patching is not yet justified.

## ForcedUpgrade milestone

This is now the highest-value path.

The XBOT ARM64 split was patched only at the ForcedUpgrade URL strings so requests go to a local Termux server. Test code:

```text
MORO42001
```

Probe mode deliberately served only `Config.xml`. XBOT then requested:

```text
/f/MORO42001/DK01.bin
```

which was intentionally blocked with 404. This proved the real XBOT ForcedUpgrade route and identified `DK01.bin` as the selected DK filename for this branch.

The server was then switched to current-image mode. XBOT successfully fetched the exact current vendor image as `DK01.bin`:

```text
HTTP 200
bytes 28444
sha256 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

This proves the entire controlled HTTP/file-selection layer.

It does **not** yet prove controller-side flashing or update ACK completion.

See `docs/09-forced-update-dk.md`.

## Current next step

Capture the controller-side update traffic during one current-image ForcedUpgrade cycle.

The native engine suggests the sequence to resolve is approximately:

```text
enter update mode
-> command 7 metadata
-> command 8 firmware chunks
-> ACK/retry
-> command 9 ending metadata / first four bytes
-> command 10 finish
```

The next milestone is not another HTTP 200. It is evidence that the controller enters update mode and ACKs the DK transfer.

## Current strategy

1. Capture full HCI/ACL during a current-image ForcedUpgrade cycle.
2. Reconstruct the exact update-mode command and ACK state machine.
3. Verify that the current-image cycle reaches and completes controller-side update mode.
4. Only after the transport is proven, compare/test a compatible alternate vendor DK or minimally modified image.
5. Keep a from-scratch motor-control firmware as a fallback, not the immediate next step.

## Evidence rule

- `GATT status=0` proves Android accepted a BLE write, not that a register changed.
- HTTP `200` proves XBOT downloaded a file, not that the controller flashed it.
- Controller readback or firmware-update ACK progression is required for controller-side claims.
