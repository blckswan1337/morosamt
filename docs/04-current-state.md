# Current state and next steps

## Proven

1. Correct BLE service and characteristics.
2. Wire-level XOR `0x34` transform.
3. ScooterIII/HB protocol family.
4. F3 direct encoding and successful 30 km/h write/readback.
5. EE scaling used by EF/F0/F1.
6. Numeric mode selector `7E` and slot mapping.
7. `C2/C4/C6` are the maxima consumed by `GetSpeedMaxAndMinVal()` for the three scaled profile branches.
8. Normal writes to EF/F0/F1 above those maxima are rejected/ignored by controller behavior.
9. A normal write to `C2` itself is also rejected by controller readback.
10. XBOT contains a real firmware/forced-upgrade engine with `UpdateApp`, `UpdataWrite`, `OnTouchUpdate`, `ForcedUpgrade/Scooter/...`, `ScooterUpdata/...`, and DK/XK/BP-family images.
11. XBOT parses a `PoJie` integer from forced-upgrade `Config.xml` and stores it at `UserInterface+0x1BAC`.
12. XBOT contains an explicit global speed-limit callback, `UserInterface::onClickLimit()`, which toggles bit 0 of map register `0x1D` and writes register `0x72` value 0/1.
13. The target HCI capture reports `0x1D=0x07F9`, so bit 0 is currently 1.
14. The controller map reports `D7=30000`; native UI code uses D7 as the maximum for the F3 speed slider, consistent with the verified 30 km/h F3 ceiling.

## PoJie status

The name is highly suggestive because `PoJie` is pinyin for 破解, roughly crack/unlock/bypass. However, the analyzed ARM64 build does not yet provide static proof that this field is consumed by the speed-limit logic.

Current xref result for `UserInterface+0x1BAC`:

- initialized/reset to zero,
- written from parsed `PoJie`,
- no direct field read has yet been found.

A native XBOT patch forced `PoJie=1` and patched the app-side displayed maximum to 30 km/h. Practical status: **no-go so far**. There is not yet evidence that this bypassed the controller's `C2/C4/C6` enforcement.

This downgrades `PoJie` from presumed active bypass to **unverified lead**.

## New highest-value live test: global limiter register 0x72

The Cocos assets contain the literal strings:

```text
Speed limit mode
Speed limit on
Speed limit off
```

and bind limiter controls to `onClickLimit()`.

For the relevant non-GoKart path, `onClickLimit()` reads `0x1D`, toggles bit 0, then calls `SendWriteCmd2(0x72, value)`.

The important mismatch is that the target's verified ScooterIII speed writes use `SendWriteCmd_HB` / address `0x20`, while this generic limiter callback uses `SendWriteCmd2`.

An isolated test patch has therefore been prepared that changes only the two `0x72` calls in `onClickLimit()` from `SendWriteCmd2` to `SendWriteCmd_HB`. It contains no PoJie changes.

The first toggle from the captured state (`0x1D` bit0=1) should request LIMIT OFF (`0x72=0`). Success requires HCI/controller readback showing `0x1D` bit0 become 0. UI state alone is not proof.

See:

- `docs/08-limit72-hb.md`
- `tools/xbot-limit72-hb.sh`

## External evidence for a lower firmware/update layer

A public 2024 reverse-engineering report describes an XBOT `ForcedUpgrade` code fetching:

```text
ForcedUpgrade/Scooter/<code>/Config.xml
ForcedUpgrade/Scooter/<code>/dk.bin
```

The author reports that interrupting the update path exposed an MCU for SWD reading, and later redirecting the XBOT firmware request to another Lebitec `ScooterUpdata/DK....bin` image restored operation. This is strong independent evidence that XBOT's update path reaches a privileged controller layer unavailable to normal parameter writes.

Lebitec also publishes a separate `ForcedUpgrade` application specifically for firmware upgrades.

## Best current strategy

Do **not** start by writing a completely new firmware.

Current order:

1. Test the app's own global limiter command `0x72` on the correct HB transport and verify `0x1D` readback.
2. If that fails, identify the exact XBOT controller/update family for the target hardware.
3. Recover the matching official/forced `Config.xml` and DK/XK/BP image.
4. Reverse the image/header/CRC and determine what is full firmware versus parameter/config payload.
5. Search the image for the current profile limits and related table structure.
6. Test whether an existing unrestricted/alternate Lebitec image or config can expose 30 km/h.
7. Patch the smallest possible existing image/config if needed.
8. Only move to a from-scratch firmware if the OEM image proves unsuitable and hardware peripherals/bootloader are fully mapped.

## Why full custom firmware is currently the worse option

A from-scratch controller firmware would require reconstructing more than the speed limiter: motor commutation/control, throttle/brake behavior, current limiting, undervoltage/overvoltage handling, thermal protection, BLE/dashboard protocol, fault handling, startup state machine, and update/bootloader compatibility.

We already know the OEM firmware can run the vehicle and that at least one branch (`F3`) accepts 30 km/h. That makes adapting the existing firmware/update path a much smaller and better-controlled problem.

## Parallel EE probe

`EE` is read by `GetWheelFactor()` and scales EF/F0/F1. A wheel-factor write probe was prepared, but the Android helper app did not run because the phone's PackageManager returned `Failed transaction (2147483646)`. Therefore **EE writability has not yet been tested**.

It remains a secondary experiment. The newly identified native `0x72` limiter switch is a cleaner and more direct target.
