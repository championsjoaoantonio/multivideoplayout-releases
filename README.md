# Multivideo Playout Releases

Public artifact channel for Multivideo Playout runtime updates.

This repository contains only immutable update artifacts generated from the
private `multivideoplayout` source repository:

- `packages/playout/<release_id>/<release_id>.json`
- `packages/playout/<release_id>/multivideo-playout-runtime-<release_id>-windows-x64.zip`
- `packages/playout/<release_id>/multivideo-playout-panel-<release_id>-windows-x64-setup.exe`
- `manifests/<channel>.json`

Do not commit source code, customer channel configuration, tokens, certificates,
private keys, logs, media files, or runtime data here.

The control-plane remains responsible for licensing, targeting, heartbeat, and
release eligibility. Playout instances download only the manifest/package URLs
returned by the control-plane.
