# XBOT global speed-limit `0x72` HB experiment

Status: **next live test, not yet controller-verified**.

## Why this path matters

The XBOT ARM64 library contains an explicit `UserInterface::onClickLimit()` implementation. The Cocos assets bind limiter controls to that callback and contain the literal UI strings:

```text
Speed limit mode
Speed limit on
Speed limit off
```

For nonzero, non-GoKart app types, the function:

1. reads local map register `0x1D`,
2. toggles bit 0,
3. sends register `0x72` with value `1` or `0` using `Bluetooth::SendWriteCmd2`.

This is distinct from the previously tested per-profile values `EF/F0/F1/F3` and their `C2/C4/C6` maxima. It is therefore a plausible global limiter-enable switch rather than another profile ceiling.

## Captured target state

The real ScooterIII/HB HCI capture contains this decoded block read:

```text
55 AA 03 20 61 1A 34 2D FF
```

The returned `0x1A...` block decodes register `0x1D` as:

```text
0x1D = 2041 = 0x07F9
```

Bit 0 is `1`.

That matches the state machine in `onClickLimit()`: the first limiter toggle from this state requests value `0`, i.e. limiter off.

## Transport mismatch discovered

The target's verified speed-profile traffic uses the ScooterIII/HB transport at address `0x20`, including `SendWriteCmd_HB` for `EF/F0/F1/F3`.

The generic `onClickLimit()` implementation instead calls `SendWriteCmd2(0x72, value)`. `SendWriteCmd2` selects one of the generic addresses and does not select HB address `0x20` for this branch.

This makes a model-branch mismatch plausible: the limiter UI exists, but its generic write path may not reach this particular ScooterIII/HB controller.

## Isolated patch

A new ARM64 split patch changes only the two calls inside `onClickLimit()`:

```text
SendWriteCmd2(0x72, 1) -> SendWriteCmd_HB(0x72, 1)
SendWriteCmd2(0x72, 0) -> SendWriteCmd_HB(0x72, 0)
```

No `PoJie` patch and no slider-max patch are included. This isolates the `0x72` hypothesis.

Native patch offsets:

```text
ELF 0x5705B0  BL SendWriteCmd2 -> BL SendWriteCmd_HB
ELF 0x5706FC  BL SendWriteCmd2 -> BL SendWriteCmd_HB
```

Original ARM64 split SHA-256:

```text
1fe680898f86018c272775148b3a19267ef2371fb170691c38d5201e35bd3de5
```

Patched split SHA-256:

```text
a1ec34aacdfee31330a70807b5bff8784003a8bdecdabd10cf84e29bd1a04fa1
```

## D7 finding

The captured controller map also contains:

```text
D7 = 30000
```

`RefreshSetting4()` and `RefrushSetMode()` read `D7` to set the maximum percentage of the `F3` speed slider. With `D7=30000`, the UI maximum resolves to 30 km/h. This is consistent with the already verified fact that `F3=30000` is accepted by the controller.

`D7` therefore looks like the F3/UI maximum, not the missing mechanism that raises the `EF/F0/F1` ceilings.

## Verification criterion for `0x72`

UI state is not accepted as proof.

After one LIMIT OFF toggle, the HCI capture must show:

1. an outgoing HB write to register `0x72`, value `0`,
2. a subsequent controller read of the `0x1A` block,
3. controller register `0x1D` bit 0 changing from `1` to `0`.

Only after that state transition is proven should actual top-speed behavior be tested.

## If this fails

If `0x72` over HB is ignored and `0x1D` remains odd, the next primary path remains the vendor forced-upgrade/config/firmware layer. A full from-scratch controller firmware is still lower priority than recovering the compatible unrestricted OEM image or its configuration delta.
