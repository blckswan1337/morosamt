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

Evidence:

- `evidence/logs/MOROBOT30_REAL.txt`

Interpretation:

The BLE transport was valid, but the assumed generic controller protocol branch was wrong for this device.

## Experiment B: HCI-derived F3=30

Status: **verified**

Initial controller value:

`F3=18000` -> 18.0 km/h

Write:

`F3=30000`

Readback:

`F3=30000` -> 30.0 km/h

Evidence:

- `evidence/logs/MOROBOT30_HCI_EXACT.txt`
- `evidence/hci/EWHEELS_HCI.cfa`
- `tools/morobot30-hci-exact.sh`

## Experiment C: ALL30 v1

Status: **partially successful, hypothesis incomplete**

Attempted to set EF/F0/F1/F3 to 30 km/h equivalents.

Initial:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=31500
```

Target scaled raw for EF/F0/F1:

`772`

Result:

```text
EE=225 EF=463 F0=515 F1=386 F2=0 F3=30000
```

Conclusion:

Only F3 changed. EF/F0/F1 writes were ignored.

Evidence:

- `evidence/logs/MOROSPEED_ALL30.txt`

## Experiment D: ALL30 v2, select mode first

Status: **rejected as sufficient explanation**

Original mode:

`7E=0`

The script explicitly selected mode 0, then wrote:

`F0=772`

Readback:

`F0=515`

Conclusion:

Selecting the matching mode before slot write was not enough.

Evidence:

- `evidence/logs/MOROSPEED_ALL30_V2.txt`

## Experiment E: ALL30 v3, raise cap first

Status: **controller cap write rejected**

Observed cap block:

```text
C2=463 C3=154 C4=515 C5=154 C6=386 C7=154
```

Attempted:

`C2=772`

Android/GATT:

`status=0`

Controller readback:

`C2=463`

The script aborted and performed best-effort rollback.

Conclusion:

The cap appears firmware/controller-enforced, or a separate privileged/factory command path is required.

Evidence:

- `evidence/logs/MOROSPEED_ALL30_V3.txt`

## Current hypothesis

The official consumer E-WHEELS path can modify profile slots only within controller-provided maxima. Raising those maxima probably requires another command family, factory/service path, firmware configuration path, or a controller firmware modification.

The XBOT ARM64 split is therefore the next authoritative reverse-engineering target.
