# Technical overview

## Target

Observed BLE address during the research session:

`EC:6E:86:06:32:29`

Android packages involved:

- E-WHEELS: `com.HB.EWHEELS`
- XBOT: `com.mini.xbot`
- MiniRobot: `com.loby.balance.car.google`

## Phase 1: generic protocol guesses

The first attempts used a known-looking `5A A5` / `55 AA` packet family and a suspected speed register around `0x74` / `0x7D`.

The important result was negative but useful:

- BLE connection succeeded.
- NUS was discovered.
- Notifications were enabled.
- Writes were queued successfully.
- Android reported `GATT WRITE status=0`.
- The controller returned no valid `0x7D` response.

The scripts therefore stopped before changing the speed.

This isolated the problem to the application protocol rather than Bluetooth transport.

## Phase 2: static analysis of E-WHEELS

The E-WHEELS native library exposed symbols including:

- `UserInterface::sliderEventMaxSpeed`
- `UserInterface::NeedSetMaxSpeed`
- `TriggerLogic::onTouchMaxSpeed`
- `Bluetooth::SendFramePack`
- `Bluetooth::SendWriteCmd2`
- `Bluetooth::SendReadCmdWithAddr2`
- `NorSpeedLimit`
- `TrainSpeedLimit`

The generic branch contained an apparent `0x7D` path, but real-device behavior proved that this controller used a different model-specific branch.

Static analysis also revealed:

- multiple packet formats
- checksum construction
- model-specific controller paths
- the existence of several speed-limit slots and limits
- later, mode/profile selection via register `7E`

## Phase 3: capture the official app

Rather than continue guessing, a real E-WHEELS Bluetooth session was captured.

On the tested Motorola / MediaTek Android build the HCI file appeared as:

`/data/misc/bluetooth/logs/BT_HCI_2026_0814_015255_UTC+0200.cfa.curf`

The file is preserved as:

`evidence/hci/EWHEELS_HCI.cfa`

## Phase 4: wire obfuscation

The decisive discovery was that E-WHEELS transforms each application-protocol byte with XOR `0x34` before sending it over BLE.

Example:

Wire:

`61 9E 37 14 55 DA 38 B5 CA`

XOR `0x34`:

`55 AA 03 20 61 EE 0C 81 FE`

This explained why earlier direct protocol frames were ignored even though the correct NUS characteristics were used.

## Phase 5: F3 speed register verified

The real E-WHEELS traffic exposed the controller's ScooterIII/HB path and an `EE..F3` block.

A captured/read value:

`F3 = 18000`

corresponded to:

`18.0 km/h`

The exact 30 km/h write was then derived:

Decoded:

`55 AA 04 20 03 F3 30 75 40 FE`

Wire after XOR `0x34`:

`61 9E 30 14 37 C7 04 41 74 CA`

The controller subsequently reported:

`F3_RAW=30000 SPEED=30.0 km/h`

This is the first fully controller-verified speed write in the project.

## Phase 6: four profile slots

Further native/HCI analysis indicated that speed control is not a single global value.

The `EE..F3` block produced:

- `EE=225`
- `EF=463`
- `F0=515`
- `F1=386`
- `F2=0`
- `F3=30000` after the successful F3 write

Using the E-WHEELS scaling constant recovered from native code:

`km/h ~= raw * EE / 5794.652832`

the first three values decode to approximately:

- `EF=463` -> 18.0 km/h
- `F0=515` -> 20.0 km/h
- `F1=386` -> 15.0 km/h

Native code maps mode register `7E` numerically:

- `7E=0 -> F0`
- `7E=1 -> EF`
- `7E=2 -> F1`
- `7E=3 -> F3`

The UI-name association Walking/Eco/Drive/Sport is still marked as not fully proven.

## Phase 7: ALL30 attempts

### ALL30 v1

Attempted to write 30 km/h equivalents directly to:

- EF
- F0
- F1
- F3

Result:

- F3 changed and verified.
- EF/F0/F1 remained unchanged.

### ALL30 v2

Hypothesis: the relevant `7E` mode must be selected before writing each slot.

The script selected `7E=0`, wrote F0=30-equivalent, then read the block.

Result:

- F0 remained `515`.
- Therefore mode selection alone was insufficient.

### ALL30 v3

Native-code analysis suggested independent upper-limit values:

- C2 for EF
- C4 for F0
- C6 for F1

The controller reported:

- `C2=463`
- `C4=515`
- `C6=386`

These exactly mirror the factory profile values.

V3 attempted:

`C2 = 772`

where `772` is the EE-scaled ~30 km/h raw value for EE=225.

Android/GATT accepted the write, but controller readback returned:

`C2=463`

The script stopped and attempted rollback.

This is strong evidence that C2/C4/C6 are controller/firmware-enforced limits rather than ordinary user-writable profile settings.

## Current direction

The next target is the full XBOT native implementation and firmware/factory configuration path.

The Android split package includes:

- `base.apk`
- `split_config.arm64_v8a.apk`
- `split_config.en.apk`
- `split_config.nb.apk`
- `split_config.xxhdpi.apk`

The ARM64 split contains:

`lib/arm64-v8a/libcpp_empty_test.so`

That native library and focused disassemblies are included in this bundle.
