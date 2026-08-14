# Current state and next steps

## Proven

1. The correct BLE service and characteristics.
2. The wire-level XOR `0x34` transform.
3. The real ScooterIII/HB protocol family.
4. F3 direct encoding and successful 30 km/h write/readback.
5. The EE scaling used by EF/F0/F1.
6. Numeric mode selector 7E and its slot mapping.
7. C2/C4/C6 mirror the observed profile ceilings.
8. A normal write to C2 is rejected by the controller.

## Not proven

1. Exact UI-label mapping of numeric modes.
2. Whether C2/C4/C6 are immutable firmware constants, protected parameters, or writable only through another command family.
3. Whether XBOT includes a factory/service or OTA path that can rewrite those limits.
4. Whether the controller firmware itself contains the limits as flash/config constants.

## Next reverse-engineering target

Full installed XBOT split set:

```text
base.apk
split_config.arm64_v8a.apk
split_config.en.apk
split_config.nb.apk
split_config.xxhdpi.apk
```

ARM64 native library:

`lib/arm64-v8a/libcpp_empty_test.so`

Search targets:

```text
SendWriteCmd
SendWriteCmd_HB
SendFramePack
firmware
upgrade
OTA
factory
C2
C4
C6
EF
F0
F1
F3
NorSpeedLimit
TrainSpeedLimit
speedLimit
```

Focused and full disassemblies are included under `reverse-engineering/`.
