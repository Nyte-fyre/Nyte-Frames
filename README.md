# Nyte Frames

Flat, resizable unit frames for **WoW: Forever**. Party and raid frames sit above
your player frame, sorted tank, healer, DPS, and grow to the left as groups are added.

## Features

- Player, target, target of target (and its target), focus, pet, party, raid (25) and boss frames
- Party and raid columns sorted by role; roles follow the group role picker, talents and raid flags
- Heal prediction, absorbs, threat border, range fade, raid marker, leader, ready check / summon / res icons
- Debuff highlight (dispel tint, bigger boss debuffs) using Blizzard's own aura display, so it works in combat
- Cast bars with a latency zone; mana tick and five-second-rule sparks on the player power bar
- Level with an Elite / Rare / Boss tag on the player and target frames
- Drag, resize, grid and snap in `/nf unlock`; profiles with import/export strings
- Border thickness, name colors, text formats, textures and fonts (LibSharedMedia)
- Optional Masque skins for the buff row and cast bar icons
- Translatable (see `Locales/`)

## Commands

- `/nf` or `/nyteframes` - settings (`/nf help` lists every command)
- `/nf unlock` / `/nf lock` - drag, resize (corner), grid, snap, arrow-key nudge
- `/nf role [name] tank|healer|dps|auto` - set a role (or Shift+right-click a party/raid frame)
- `/nf role refresh` - re-check everyone's talents after a respec
- `/nf profiles` - switch, copy, rename, delete or reset profiles
- `/nf export` / `/nf import` - share settings as a `NYTEFRAMES1:` string
- `/nf blizzard` - which Blizzard frames are hidden or showing
- `/nf errors` - errors the addon caught

## Translating

`Locales/_template.lua` lists every string. Copy it to `Locales/<code>.lua`
(for example `deDE.lua`), set the code in `NF.NewLocale("deDE")`, translate the
right-hand sides (keep `%s` / `%d`), and add the file to `NyteFrames.toc` after
`Core\Locale.lua`. Untranslated lines fall back to English.

## Development

- `python tests/run.py` runs the offline tests (needs `pip install lupa`).
- `python tools/locale_keys.py` rebuilds the translation template.
- `python tests/read_probe.py` summarizes the API probe data from your SavedVariables.
- `powershell -ExecutionPolicy Bypass -File tools\install.ps1` links the repo into
  the Forever AddOns folder.
- Releases: pushing a `v*` tag makes CurseForge package it (webhook + `.pkgmeta`).

## License

MIT, see `LICENSE`. Bundled libraries (LibStub, CallbackHandler-1.0,
LibSharedMedia-3.0, LibSerialize, LibDeflate) keep their own licenses in `Libs/`.
