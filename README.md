# Nyte Frames

Flat, resizable unit frames for **WoW: Forever**. Party and raid frames sit above
your player frame, sorted tank, healer, DPS, and grow to the left as groups are added.

**Status: v0.1.0, milestone 1 (skeleton + API probe).** No frames yet. This build
records what the client lets addons read, so the frames can be designed around it.

## Commands

- `/nf` or `/nyteframes` - help
- `/nf probe` - probe status (it records by itself)
- `/nf probe now` - take a snapshot now
- `/nf probe inspect` - test talent inspection on your target
- `/nf probe off | on | reset`
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
