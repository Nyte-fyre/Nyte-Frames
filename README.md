# Nyte Frames

Flat, resizable unit frames for **WoW: Forever**. Party and raid frames sit above
your player frame, sorted tank, healer, DPS, and grow to the left as groups are added.

**Status: v0.8.0, milestone 8: all frames incl. boss stack, Blizzard-drawn auras, cast bars, overlays.** The probe still
records what the client lets addons read.

## Commands

- `/nf` or `/nyteframes` - settings (`/nf help` for commands)
- `/nf unlock` / `/nf lock` - drag, resize (corner), grid, snap, arrow-key nudge
- `/nf role [name] tank|healer|dps|auto` - set a role (or Shift+right-click a party/raid frame)
- `/nf probe` - probe status (it records by itself)
- `/nf probe now` - take a snapshot now
- `/nf probe inspect` - test talent inspection on your target
- `/nf probe off | on | reset`
- `/nf auras` - status of the Blizzard aura icons shown on Nyte frames
- `/nf errors` - errors the addon caught
- `/nf profile` - the active profile

## Development

- `python tests/run.py` runs the offline tests (needs `pip install lupa`), including
  the raid sorting worked example.
- `python tests/read_probe.py` summarizes the probe data from your SavedVariables.
- `powershell -ExecutionPolicy Bypass -File tools\install.ps1` links the repo into
  the Forever AddOns folder.

## Libraries

LibStub, CallbackHandler-1.0, LibSharedMedia-3.0, LibSerialize, LibDeflate, each
under its own license in `Libs/`.
