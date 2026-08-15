# XBOT global speed-limit `0x72` HB experiment

Status: **controller-tested and rejected.**

## Why this path mattered

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

The target's verified ScooterIII speed writes use `SendWriteCmd_HB` / address `0x20`, so an isolated patch changed only the two `0x72` calls in `onClickLimit()` from `SendWriteCmd2` to `SendWriteCmd_HB`.

## Captured target state

The controller reports:

```text
0x1D = 0x07F9
bit0 = 1
```

The first limiter toggle from this state should request limiter off.

## Direct HB command

The final test bypassed the UI entirely and sent the HB command directly through a root Android `BluetoothGatt` client.

Decoded write:

```text
55 AA 04 20 03 72 00 00 66 FF
```

Wire form after XOR `0x34`:

```text
61 9E 30 14 37 46 34 34 52 CB
```

Android returned:

```text
GATT WRITE status=0
```

The controller was then read again. It still returned:

```text
0x1D = 0x07F9
bit0 = 1
```

Final result:

```text
LIMIT WRITE REJECTED
```

## Conclusion

The `0x72` hypothesis is now closed for this controller/configuration. Changing the transport from generic `SendWriteCmd2` to `SendWriteCmd_HB` does not disable the controller-side limiter state.

This reinforces the evidence that the protected speed behavior sits below ordinary writable HB registers.

## D7 finding remains valid

The captured controller map contains:

```text
D7 = 30000
```

`RefreshSetting4()` and `RefrushSetMode()` use `D7` to set the maximum of the `F3` speed slider. This is consistent with the independently verified fact that `F3=30000` is accepted and reads back as 30 km/h.

`D7` is therefore useful evidence for the F3 branch, but it is not the missing mechanism for raising the protected EF/F0/F1 ceilings.

## Next layer

The primary path is now XBOT/Lebitec ForcedUpgrade. The HTTP/file-selection side of that path has subsequently been verified, including a controlled local `Config.xml` and successful XBOT retrieval of `DK01.bin`.

See `docs/09-forced-update-dk.md`.
