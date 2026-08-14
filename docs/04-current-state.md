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

## PoJie status

The name is highly suggestive because `PoJie` is pinyin for 破解, roughly crack/unlock/bypass. However, the analyzed ARM64 build does not yet provide static proof that this field is consumed by the speed-limit logic.

Current xref result for `UserInterface+0x1BAC`:

- initialized/reset to zero,
- written from parsed `PoJie`,
- no direct field read has yet been found.

A native XBOT patch forced `PoJie=1` and patched the app-side displayed maximum to 30 km/h. Practical status: **no-go so far**. There is not yet evidence that this bypassed the controller's `C2/C4/C6` enforcement.

This downgrades `PoJie` from presumed active bypass to **unverified lead**.

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

The evidence supports this order instead:

1. Identify exact XBOT controller/update family for the target hardware.
2. Recover the matching official/forced `Config.xml` and DK/XK/BP image.
3. Reverse the image/header/CRC and determine what is full firmware versus parameter/config payload.
4. Search the image for the current profile limits and related table structure.
5. Test whether an existing unlocked/alternate Lebitec image or config can expose 30 km/h.
6. Patch the smallest possible existing image/config if needed.
7. Only move to a from-scratch firmware if the OEM image proves unsuitable and hardware peripherals/bootloader are fully mapped.

## Why full custom firmware is currently the worse option

A from-scratch controller firmware would require reconstructing more than the speed limiter: motor commutation/control, throttle/brake behavior, current limiting, undervoltage/overvoltage handling, thermal protection, BLE/dashboard protocol, fault handling, startup state machine, and update/bootloader compatibility.

We already know the OEM firmware can run the vehicle and that at least one branch (`F3`) accepts 30 km/h. That makes adapting the existing firmware/update path a much smaller and better-controlled problem.

## Parallel low-risk probe

`EE` is read by `GetWheelFactor()` and appears to scale EF/F0/F1. A wheel-factor write probe was prepared, but the Android helper app did not run because the phone's PackageManager returned `Failed transaction (2147483646)`. Therefore **EE writability has not yet been tested**.

This remains worth testing because a writable EE could alter effective profile speeds without touching C2/C4/C6, although it could also distort speed/odometer calculations.
