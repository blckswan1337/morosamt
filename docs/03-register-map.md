# Register map, current snapshot

| Register | Observed / interpreted role | Encoding / observed value | Status |
|---|---|---|---|
| `7E` | Numeric drive mode / profile selector | 0..3 | Native-code mapping established |
| `EE` | Wheel/speed scaling parameter | 225 | Observed |
| `EF` | Profile speed slot | 463 ~= 18 km/h | Observed |
| `F0` | Profile speed slot | 515 ~= 20 km/h | Observed |
| `F1` | Profile speed slot | 386 ~= 15 km/h | Observed |
| `F2` | Unknown / zero in captures | 0 | Observed only |
| `F3` | Direct max-speed slot on active HB branch | raw = km/h*1000 | Write + readback verified |
| `C2` | Upper-limit value associated with EF | 463 | Read observed; attempted raise rejected |
| `C4` | Upper-limit value associated with F0 | 515 | Read observed |
| `C6` | Upper-limit value associated with F1 | 386 | Read observed |

Numeric profile mapping recovered from E-WHEELS native logic:

```text
7E=0 -> F0
7E=1 -> EF
7E=2 -> F1
7E=3 -> F3
```

Human-facing label mapping to Walking / Eco / Drive / Sport remains deliberately unconfirmed in this snapshot.
