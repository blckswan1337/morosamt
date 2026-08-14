# Experiment ledger

This file separates verified observations from hypotheses and rejected hypotheses.

## Experiment A: 0x7D generic probe

Status: **rejected for this controller path**

Observed:

- BLE connection: success
- NUS discovery: success
- CCCD enable: success
- GATT writes: status 0
- valid `0x7D` response: none
- permanent write: none

Interpretation: BLE transport was valid, but the assumed generic controller branch was wrong.

## Experiment B: HCI-derived F3=30

Status: **verified**

Initial controller value:

`F3=18000` -> 18.0 km/h

Write:

`F3=30000`

Readback:

`F3=30000` -> 30.0 km/h

Conclusion: 30 km/h is demonstrably possible on at least the F3 branch without replacing controller firmware.

## Experiment C: ALL30 v1

Status: **partially successful, hypothesis incomplete**

Attempted to set EF/F0/F1/F3 to 30 km/h equivalents.

Target scaled raw for EF/F0/F1:

`772`

Result:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
```

Conclusion: only F3 changed. EF/F0/F1 writes were ignored.

## Experiment D: ALL30 v2, select mode first

Status: **rejected as sufficient explanation**

Original mode:

`7E=0`

The script explicitly selected mode 0 and wrote `F0=772`.

Readback:

`F0=515`

Conclusion: selecting the corresponding mode was not enough.

## Experiment E: ALL30 v3, raise cap first

Status: **controller cap write rejected**

Observed:

```text
C2=463 C3=154 C4=515 C5=154 C6=386 C7=154
```

Attempted:

`C2=772`

Android/GATT:

`status=0`

Controller readback:

`C2=463`

Conclusion: C2/C4/C6 are not ordinary writable user parameters through the same command path.

## Experiment F: EE wheel-factor write probe

Status: **not executed**

Reason: Android PackageManager failed while installing/running the helper:

```text
cmd: Failure calling service package: Failed transaction (2147483646)
```

No BLE EE write was sent. EE writability remains unknown.

## Experiment G: XBOT PoJie native patch

Status: **no-go so far / not a verified bypass**

Static findings:

- `PoJie` string exists in XBOT native code.
- forced-upgrade `Config.xml` parser reads it as an integer.
- value is stored at `UserInterface+0x1BAC`.
- reset/init code clears the same field.
- no direct read/consumer of `+0x1BAC` has yet been found in the analyzed ARM64 binary.

Patch hypothesis:

1. force `PoJie=1` after reset,
2. force parsed/missing PoJie to 1,
3. force XBOT's app-visible speed maximum to 30 km/h.

Deployment used a root bind-overlay idea for the already-installed ARM64 split to avoid relying on the unstable PackageManager.

Practical result reported by user: **no-go so far**.

Interpretation: `PoJie` may be legacy, controller-family-specific, consumed indirectly, or unrelated to the speed-limit enforcement. It must not currently be documented as a proven unlock switch.

## Experiment H: forced-upgrade path as privileged layer

Status: **strong lead, not yet tested on this target**

XBOT native code includes a complete firmware-update state machine and forced-upgrade path. Independent public reporting describes XBOT ForcedUpgrade being used to access/update Lebitec scooter controller firmware and redirecting a forced-upgrade download to another Lebitec DK firmware image.

Interpretation: the firmware/update path is a better candidate for bypassing immutable C2/C4/C6 limits than further normal register writes.

## Current working hypothesis

The consumer parameter path modifies EF/F0/F1 only inside controller-provided maxima. F3 is different and already accepts 30 km/h. The unresolved profile limits likely live in firmware/configuration below the normal parameter layer.

The preferred direction is therefore to recover and modify the smallest existing Lebitec firmware/config artifact necessary, rather than writing a completely new motor-controller firmware from scratch.
