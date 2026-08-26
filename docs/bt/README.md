# BT

Browser-first Bluetooth toolkit forked out of MOROSAMT.

## Scope

- Web Bluetooth device chooser and reconnect to previously authorised devices
- GATT service/characteristic inventory
- safe read-only reads where characteristics allow `read`
- automatic profile JSON generation
- universal config/blob parser
- format guessing with confidence
- conversions between UTF-8, HEX, Base64, decimal bytes and escaped byte notation
- whitespace-tolerant HEX/Base64 handling
- UUID extraction and Bluetooth/protocol clues
- JSON and key=value/INI-ish parsing
- local-only analysis in the browser

## Use

Open `/bt/` from the MOROSAMT GitHub Pages deployment.

Web Bluetooth requires a secure context (HTTPS) and a browser that exposes the Web Bluetooth API. Device discovery always requires user interaction with the browser chooser.

The toolkit defaults to discovery/read-only analysis. It does not automatically write arbitrary values to unknown GATT characteristics.
