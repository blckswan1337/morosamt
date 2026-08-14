# Protocol reference

## BLE

Nordic UART Service:

```text
Service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
RX       6E400002-B5A3-F393-E0A9-E50E24DCCA9E
TX       6E400003-B5A3-F393-E0A9-E50E24DCCA9E
CCCD     00002902-0000-1000-8000-00805F9B34FB
```

Target observed during testing:

`EC:6E:86:06:32:29`

## Wire transform

Every decoded protocol byte is XOR'd with `0x34` on the BLE wire.

```text
wire = decoded XOR 0x34
decoded = wire XOR 0x34
```

## Confirmed read

Decoded EE-block read:

`55 AA 03 20 61 EE 0C 81 FE`

BLE wire:

`61 9E 37 14 55 DA 38 B5 CA`

## Confirmed F3 write

30.0 km/h:

```text
30000 decimal
0x7530
little-endian 30 75
```

Decoded:

`55 AA 04 20 03 F3 30 75 40 FE`

Wire:

`61 9E 30 14 37 C7 04 41 74 CA`

Verified readback:

`F3=30000`

## EE..F3 block

Observed:

```text
EE = 225
EF = 463
F0 = 515
F1 = 386
F2 = 0
F3 = 30000
```

For EF/F0/F1, the recovered E-WHEELS conversion is approximately:

```text
km/h = raw * EE / 5794.652832
raw  = km/h * 5794.652832 / EE
```

For EE=225:

```text
30 km/h -> int(30 * 5794.652832 / 225) = 772
```

Approximate decoded speeds:

```text
EF 463 -> 18.0 km/h
F0 515 -> 20.0 km/h
F1 386 -> 15.0 km/h
```

F3 uses the separate direct `km/h * 1000` encoding.

## Mode mapping

Recovered from E-WHEELS native logic:

```text
7E=0 -> F0
7E=1 -> EF
7E=2 -> F1
7E=3 -> F3
```

Do not treat this as a proven Walking/Eco/Drive/Sport label mapping yet. Only the numeric mapping is currently considered established.

## Per-profile limits

Observed C2-block:

```text
C2 = 463
C3 = 154
C4 = 515
C5 = 154
C6 = 386
C7 = 154
```

Working interpretation from native code and behavior:

```text
C2 -> upper limit associated with EF
C4 -> upper limit associated with F0
C6 -> upper limit associated with F1
```

Direct C2 write test:

```text
requested C2 = 772
GATT write status = 0
readback C2 = 463
```

Therefore the controller rejected the new cap value.
