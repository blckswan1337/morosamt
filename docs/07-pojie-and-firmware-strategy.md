# PoJie and firmware strategy

Status: 2026-08-14

## Executive conclusion

The evidence currently favors **not** writing a completely new controller firmware as the first route to 30 km/h.

There is already a proven 30 km/h-capable software path in this controller family:

- the tested controller accepts and reads back `F3=30000`,
- E-Wheels has sold closely related E2S V2 / Long Range models as both restricted and 30 km/h variants,
- XBOT/LebiTEC explicitly contains a forced-firmware-upgrade system,
- public reports document XBOT forced-firmware codes that switch compatible controllers to international 30–35 km/h firmware.

The safer engineering direction is therefore:

1. identify the exact controller/firmware family,
2. recover the matching unrestricted vendor firmware or forced-upgrade package,
3. compare it to the restricted image,
4. patch the smallest possible parameter/config/firmware region if necessary,
5. retain the stock bootloader/update transport and rollback path.

A ground-up replacement firmware should be treated as the last resort.

## PoJie finding

The ARM64 XBOT library contains the literal XML attribute name:

`PoJie`

In Chinese reverse-engineering/software terminology, `破解` (`pojie`) commonly means crack, unlock, bypass, or break a restriction.

Static analysis of the exact XBOT split used in this project shows that `UserInterface::GetConfigFileFinish()` reads the `PoJie` integer attribute from downloaded XML and stores it at the `UserInterface` object offset `+0x1BAC`.

Relevant native behavior:

```text
FindAttribute("PoJie")
QueryIntValue(...)
store value -> UserInterface + 0x1BAC
```

The same field is initialized/reset to zero elsewhere.

However, a whole-library disassembly search has so far found **writes but no demonstrated read/use of that field in the speed-control path**. Therefore `PoJie` is interesting, but it is not yet evidence of a live speed-limit bypass in this build.

## PoJie app patch experiment

A test patch was produced under the explicit working assumption that `PoJie` is functional:

- force `PoJie=1` during reset,
- force parsed/missing `PoJie` to 1,
- force the XBOT-visible max returned by `GetSpeedMaxAndMinVal()` to 30 km/h.

Result reported by the tester: **no go**.

Interpretation:

This is consistent with the existing controller evidence. `GetSpeedMaxAndMinVal()` determines the app-side slider range, but the physical controller still enforces the C2/C4/C6 ceilings. Raising the UI maximum cannot by itself change firmware-owned limits.

This result reduces confidence that the present `PoJie` field is the runtime speed-unlock switch. It may instead be:

- an obsolete/dead feature,
- used only by another controller family,
- used indirectly in code not yet identified,
- or related to firmware selection/update eligibility rather than real-time speed writes.

## Why full custom firmware is premature

A complete replacement firmware would require reconstructing or reimplementing substantially more than the speed limiter:

- motor commutation/control,
- current and voltage limiting,
- throttle and brake behavior,
- E-ABS/regenerative braking,
- hall/speed sensing,
- thermal and undervoltage protection,
- display/controller communications,
- BLE-facing configuration protocol,
- persistent settings,
- watchdog/fault handling,
- bootloader/update compatibility.

The project already has evidence that the vendor firmware family can operate this hardware at 30 km/h, which makes replacing all of that logic unnecessarily expensive and risky unless the stock image is cryptographically or technically impossible to modify.

## Strong evidence for a vendor-firmware route

### XBOT contains a real forced-upgrade engine

The native library contains URL templates such as:

```text
ForcedUpgrade/Scooter/%s/Config.xml
ForcedUpgrade/Scooter/%s/DK.bin
ForcedUpgrade/Scooter/%s/DK01.bin
ForcedUpgrade/Scooter/%s/XK.bin
ForcedUpgrade/Scooter/%s/BP.binLB
ForcedUpgrade/Scooter/%s/BP1.binLB
ForcedUpgrade/Scooter/%s/BP2.binLB
ScooterUpdata/Config.xml
ScooterUpdata/DK%08x.bin
ScooterUpdata/XK%08x.bin
```

The update implementation contains a controller bootloader/update sequence and firmware transfer logic rather than merely an app-setting write.

### Public XBOT reports independently match this architecture

Public scooter communities document XBOT's `Forced Firmware upgrade` feature and controller-specific codes that load an international firmware and raise top speed to about 30–35 km/h on compatible XBOT-family controllers.

Those reports also contain brick/error cases when firmware intended for a different controller is flashed. This reinforces that the critical problem is **firmware-family identification**, not inventing a brand-new firmware.

### E-Wheels sold 30 km/h variants

Public E-Wheels/retailer material states that E2S V2 / Long Range variants exist as 20 km/h restricted and 30 km/h unrestricted configurations, with otherwise closely related hardware. That makes a vendor configuration/firmware difference more likely than a fundamental hardware limitation.

## Current controller evidence

Verified profile values:

```text
EE = 225
EF = 463 ~= 18 km/h
F0 = 515 ~= 20 km/h
F1 = 386 ~= 15 km/h
F3 = 30000 = 30 km/h
```

Verified upper-limit values:

```text
C2 = 463
C4 = 515
C6 = 386
```

The app-side mode/profile mapping recovered from native code is:

```text
7E=0 -> F0
7E=1 -> EF
7E=2 -> F1
7E=3 -> F3
```

Attempts to write 30 km/h equivalents directly to EF/F0/F1 were ignored. An attempt to raise C2 from 463 to 772 was also ignored on controller readback even though Android reported successful GATT delivery.

This means the restriction lies below the ordinary XBOT/E-WHEELS parameter-write layer.

## Recommended path

### Priority 1: identify exact unrestricted image

Reverse the XBOT forced-upgrade lookup and determine the values used in the `%s` path for this controller. Capture the actual `Config.xml` request or reconstruct the model/version key from native code and controller registers.

Then locate the exact DK/XK/BP image family corresponding to this controller.

### Priority 2: compare restricted vs unrestricted firmware

If both variants can be obtained, compare them before writing anything. Search first for:

```text
463
515
386
772
225
20 km/h / 30 km/h conversion constants
C2/C4/C6-like parameter tables
country / region flags
checksum / config blocks
```

The ideal outcome is a tiny configuration difference rather than executable-code modification.

### Priority 3: vendor firmware patch

If the international firmware is hardware-compatible but cannot be selected normally, patch the vendor image while preserving its original bootloader protocol and all motor-control logic.

### Priority 4: custom firmware only if required

Write a ground-up controller firmware only if:

- vendor images cannot be recovered,
- the speed limit is cryptographically locked in an inaccessible region,
- or the controller MCU/bootloader prevents useful modification of the stock image.

## Current assessment

Best current bet for reaching 30 km/h:

**vendor international / forced-upgrade firmware or a minimal patch to that firmware, not a full firmware rewrite.**

The PoJie clue remains worth tracing, particularly around forced-upgrade configuration and model eligibility, but the first app-side PoJie/max-slider patch produced no speed-unlock result and should be recorded as a negative experiment rather than treated as a working bypass.
