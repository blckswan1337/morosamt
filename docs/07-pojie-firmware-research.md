# PoJie and firmware strategy research

Status: 2026-08-14

## Question

Is the best route to 30 km/h a completely new controller firmware, or can it be achieved through existing XBOT/Lebitec mechanisms?

## Short answer

Current evidence strongly favors **using or adapting the existing firmware/update/configuration path first**. A completely new firmware should be the fallback, not the first plan.

30 km/h is already proven possible on the target controller through `F3=30000`. The unresolved issue is that EF/F0/F1 are bounded by `C2/C4/C6`.

## PoJie static analysis

The XBOT ARM64 library contains the literal string:

```text
PoJie
```

`UserInterface::GetConfigFileFinish()` parses the attribute and stores it at:

```text
UserInterface + 0x1BAC
```

Relevant behavior:

```text
FindAttribute("PoJie")
QueryIntValue(...)
store parsed value -> [UserInterface + 0x1BAC]
```

Reset/init code clears the same field.

A full ARM64 disassembly search has so far found the field as an explicit destination, but **no direct load of `[UserInterface + 0x1BAC]`** in the speed-setting path or elsewhere.

Therefore:

- the name is suggestive,
- the field is definitely supplied by server-side forced-upgrade configuration,
- but it is not yet proven to be an active speed unlock in this XBOT build.

The first native patch that forced PoJie to 1 and raised the UI maximum to 30 km/h has not yet produced a demonstrated controller-side bypass. Status: **no-go so far**.

## Why PoJie is still interesting

`PoJie` is pinyin for Chinese 破解, generally used for crack/unlock/bypass. Its location inside the forced-upgrade configuration parser makes it more interesting than a random UI string.

Possible explanations for the missing direct xref include:

1. legacy/dead field retained across app versions,
2. only used by another controller family,
3. indirect use through copied structures or code not reached by a simple field-offset search,
4. server-side marker that selects a different firmware rather than changing local app logic,
5. marker used by code stripped or disabled in this particular build.

At present, #4 is particularly plausible because the surrounding system contains a substantial forced-firmware delivery mechanism.

## XBOT firmware/update engine

The native library contains:

```text
Bluetooth::OnTouchUpdate
Bluetooth::UpdateApp
Bluetooth::UpdataWrite
```

and firmware paths including:

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

The update state machine uses dedicated update commands and firmware chunk transfer, separate from ordinary `SendWriteCmd_HB()` parameter writes.

This provides a technically credible layer below the `C2/C4/C6` register enforcement.

## Independent public evidence

A 2024 electronics-forum reverse-engineering thread reports the following XBOT/Lebitec workflow:

- an XBOT forced-upgrade code causes the app to fetch a Lebitec URL under `ForcedUpgrade/Scooter/<code>/Config.xml`,
- the associated controller image is `dk.bin`,
- the author reports that entering forced-upgrade mode exposed a previously protected MCU for SWD reading after the process was interrupted,
- the author later redirected the XBOT firmware request to another official Lebitec `ScooterUpdata/DK....bin` image and restored operation.

This is anecdotal third-party evidence, not proof for the present hardware, but it independently confirms that the XBOT forced-upgrade path is a real privileged controller update mechanism rather than a decorative UI feature.

Public source:

- https://mekatronik.org/forum/threads/korumali-mcu-dan-gomulu-yazilimi-cikarma.5202/
- https://mekatronik.org/forum/threads/korumali-mcu-dan-gomulu-yazilimi-cikarma.5202/page-2

Lebitec's own download page describes XBOT as able to set vehicle parameters, while several related Lebitec scooter applications advertise firmware upgrade capability:

- https://www.lebitec.com/index.php/xiazai/

Lebitec also distributes a separate `ForcedUpgrade` application for scooter/balance-vehicle firmware updates.

## External evidence that existing firmware can carry higher speed limits

Retail listings exist for controllers using the Lebitec `ForcedUpgrade` app and advertising selectable scooter modes up to 35 km/h. This does not establish binary compatibility with the present MOROBOT/XBOT controller, but it shows that the Lebitec ecosystem contains controller/firmware combinations where higher speed profiles are configured without designing a controller firmware from zero.

Example public listing:

- https://allegro.pl/produkt/sterownik-do-hulajnogi-xiaomi-electric-scooter-4-pro-35km-h-mi-4-pro-259ddf01-ad37-499a-a981-fe52f1b2ab44

## Why a from-scratch firmware is premature

A totally new motor-controller firmware would require reproducing much more than a speed-limit constant:

- motor commutation/control loop,
- throttle mapping,
- brake/regeneration behavior,
- current and torque limiting,
- battery undervoltage/overvoltage behavior,
- thermal protection,
- hall/sensor handling,
- startup and fault state machines,
- display/BLE protocol compatibility,
- persistent configuration,
- bootloader/update compatibility,
- safe failure behavior.

The OEM controller already performs all of these functions and has been observed accepting 30 km/h on F3. Reusing that implementation and altering the smallest relevant configuration is therefore both simpler and more testable.

## Recommended order of attack

### 1. Identify firmware family

Determine whether the target controller corresponds to DK, XK, BP, or another branch using XBOT's own version/model/update-selection logic.

### 2. Recover exact official update metadata

Obtain the target's normal and, if discoverable, forced-upgrade `Config.xml` and image names without flashing anything.

### 3. Reverse the image container

Determine:

- header layout,
- component/version fields,
- load/flash offsets,
- CRC/checksum rules,
- whether the downloaded image is full firmware or a partial update.

### 4. Diff compatible official images

If multiple versions/regions exist, diff them and search for structures that correlate with known values:

```text
C2 = 463
C4 = 515
C6 = 386
EE = 225
```

Even if these exact runtime values are transformed before storage, neighboring table patterns and mode ordering may identify the limiter table.

### 5. Prefer an existing unlocked image/config

If a compatible official or forced image already exposes 30+ km/h, that is preferable to a hand-written controller firmware.

### 6. Patch the smallest artifact

If no suitable image exists, patch the existing OEM image/config while preserving the controller's motor-control and protection logic.

### 7. Full custom firmware only as last resort

Consider a new firmware only after:

- MCU is identified,
- full firmware or a recoverable backup is available,
- SWD/JTAG/bootloader recovery is known,
- peripheral pinout is mapped,
- motor-control topology is understood,
- existing image cannot be safely modified.

## Parallel path: EE / wheel factor

`GetWheelFactor()` reads `EE` and uses:

```text
factor = EE / 5794.652832
```

A write probe was prepared to test whether EE is mutable. The test has **not run** because Android PackageManager failed while launching the helper. No conclusion about EE writability should be drawn yet.

If EE is writable, it could change the effective interpretation of EF/F0/F1 and therefore provide another non-firmware route. It could also distort displayed speed and odometer distance, so it should be treated as an experiment rather than the preferred production solution.

## Current verdict

Likelihood ranking based on present evidence:

1. **Existing Lebitec forced-update / alternate firmware / config path**: highest-value route.
2. **Small patch to existing OEM firmware/config**: likely next if no ready-made unlocked image exists.
3. **EE/wheel-factor manipulation**: worth testing as a shortcut, but may produce incorrect telemetry.
4. **PoJie-only app patch**: currently weak after first no-go and missing consumer xrefs.
5. **Completely new motor-controller firmware**: unnecessary complexity unless all OEM routes fail.

The research target is therefore not "write a new firmware" yet. It is "recover the correct existing firmware/update path and find where the controller's profile ceilings are defined."
