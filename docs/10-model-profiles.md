# Model profiles: V2 LR and V2 Pro LR

The tooling now treats **E-Wheels E2S V2 Long Range** and **E-Wheels E2S V2 Pro Long Range** as separate controller profiles instead of assuming that one firmware identity applies to both.

E-Wheels currently lists separate controller-board variants:

- V2 Long Range / V3 controller: SKU 9433
- V2 Pro Long Range / V3 Pro controller: SKU 9444

The shared display/motor ecosystem does not imply identical controller firmware.

## `v2-pro-lr`

Status: **verified live target profile in this research**.

```text
profile            = v2-pro-lr
model              = E-Wheels E2S V2 Pro Long Range
controller SKU     = 9444
DK_MODEL           = 0x84A8
DK_ID              = 0x061007F9
DK version decimal = 33960
DK file            = DK061007f9.bin
DK size            = 28444 bytes
DK SHA-256          = 856c19b176f9e8d1f73f627e731e4a991282c9fba2a136b14651831b981bff62
```

The verified local ForcedUpgrade route for this profile requests `DK01.bin`.

`probe` and `current` are enabled for this profile.

## `v2-lr`

Status: **included as a distinct profile, live DK identity not yet verified**.

```text
profile        = v2-lr
model          = E-Wheels E2S V2 Long Range
controller SKU = 9433
```

Probe and HCI capture are allowed, but the local tool deliberately blocks `current` firmware arming until a live V2 LR controller identity and matching vendor DK image have been recovered.

This avoids silently treating a V2 Pro LR image as compatible with V2 LR.

## Tool selection

```sh
MOROSAMT_MODEL=v2-pro-lr bash tools/morosamt-forced-dk-local.sh probe
MOROSAMT_MODEL=v2-lr     bash tools/morosamt-forced-dk-local.sh probe
```

The same selector is accepted by `tools/morosamt-forced-hci.sh` and is written into capture metadata.

Show profiles with:

```sh
bash tools/morosamt-forced-dk-local.sh profiles
```

## Compatibility rule

Marketing model names are metadata, not sufficient firmware identifiers. Firmware exposure should require a controller-derived DK identity plus a recovered matching vendor image. A profile may therefore support routing/capture before it supports actual `current` firmware mode.
