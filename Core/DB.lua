-- DB.lua: SavedVariables, defaults, profiles, schema migrations.
--
-- NyteFramesDB (account):   { schema, profiles = { [name] = profile }, chars = { [charKey] = profileName } }
-- NyteFramesCharDB (char):  { profileName, backup = <copy of the active profile>, savedAt }
--
-- The per-character backup exists because this client has a known bug where
-- account-wide SavedVariables sometimes fail to load. If the account file
-- comes back empty, the active profile is restored from the character file.
--
-- DEFAULTS is the single source of truth: profiles are filled from it, and
-- import validation (milestone 9) checks types against it.
local _, NF = ...
local DB = {}
NF.DB = DB

DB.SCHEMA = 2
DB.DEFAULT_PROFILE = "Default"

-- Reference screen the default layout was measured on (author's screenshot).
-- Positions are stored as offsets from UIParent's CENTER in reference pixels
-- and scaled by UIParent height / REF_H the first time a frame is placed;
-- after that, real offsets are saved on drag.
DB.REF_W, DB.REF_H = 1917, 1037

local function frameDefaults(t)
  local base = {
    enabled = true,
    width = 120, height = 40,
    pos = nil,                 -- { point, relPoint, x, y } once placed/dragged
    refPos = { x = 0, y = 0 }, -- center offset in reference pixels
    powerHeightPct = 20,       -- 0 hides the power bar
    textMode = nil,            -- nil = use general.textMode
    nameColor = "white",       -- "class" | "white" | "reaction" (white reads best on class-colored bars)
    showName = true, showHealthText = true, showPowerText = false,
    auras = {
      buffs = true, debuffs = true, max = 8, size = 18, growth = "RIGHT",
      onlyMine = false, hideLong = false, dispellableFirst = false, filter = {},
    },
    castBar = false,
    overlays = { healPrediction = true, healMineOnly = false, absorbs = true,
                 threat = true, dispelHighlight = true, rangeFade = false },
    icons = { raidTarget = true, leader = true, role = false },
  }
  for k, v in pairs(t) do base[k] = v end
  return base
end

DB.DEFAULTS = {
  general = {
    textMode = "percent",      -- "number" | "percent" | "both" for every non-player frame
    abbreviate = true,         -- 12.3k / 1.2m
    texture = "Nyte Flat",
    font = "Friz Quadrata TT",
    fontSize = 11,
    rangeAlpha = 0.45,
    smallPowerPct = 10,        -- default split for party/raid
    largePowerPct = 20,        -- default split for player/target
    hideBlizzardCastBar = true,
    blizzardAuras = true,      -- show Blizzard's own aura icons on our frames (works in combat)
  },
  frames = {
    player = frameDefaults({ width = 195, height = 60, refPos = { x = -271, y = -201 },
      showPowerText = true, castBar = true,
      auras = { buffs = false, debuffs = false, max = 16, size = 20, growth = "RIGHT",
        onlyMine = false, hideLong = false, dispellableFirst = false, filter = {} } }),
    target = frameDefaults({ width = 195, height = 60, refPos = { x = 289, y = -201 },
      castBar = true, auras = { buffs = true, debuffs = true, max = 16, size = 20, growth = "RIGHT",
        onlyMine = false, hideLong = false, dispellableFirst = false, filter = {} } }),
    targettarget = frameDefaults({ width = 120, height = 32, refPos = { x = 287, y = -114 },
      powerHeightPct = 15, auras = { buffs = false, debuffs = false, max = 0, size = 14, growth = "RIGHT",
        onlyMine = false, hideLong = false, dispellableFirst = false, filter = {} } }),
    targettargettarget = frameDefaults({ width = 120, height = 32, refPos = { x = 287, y = -78 },
      powerHeightPct = 15, auras = { buffs = false, debuffs = false, max = 0, size = 14, growth = "RIGHT",
        onlyMine = false, hideLong = false, dispellableFirst = false, filter = {} } }),
    focus = frameDefaults({ enabled = false, width = 150, height = 40, refPos = { x = 520, y = -201 } }),
    pet = frameDefaults({ enabled = false, width = 120, height = 26, refPos = { x = -271, y = -250 },
      powerHeightPct = 15 }),
    -- party/raid: Blizzard raid-frame scale (~95x45 per member in the reference)
    party = frameDefaults({ width = 95, height = 45, powerHeightPct = 10, spacing = 2,
      -- shift of the whole group from its spot above the player frame; the
      -- reference screenshot has the group frames ~20px above the player frame
      offset = { x = 0, y = 18 },
      overlays = { healPrediction = true, healMineOnly = false, absorbs = true, threat = true,
                   dispelHighlight = true, rangeFade = true },
      icons = { raidTarget = true, leader = true, role = true },
      auras = { buffs = false, debuffs = true, max = 3, size = 14, growth = "LEFT",
        onlyMine = false, hideLong = true, dispellableFirst = true, filter = {} } }),
    raid = frameDefaults({ width = 95, height = 45, powerHeightPct = 10, spacing = 2,
      offset = { x = 0, y = 18 },
      maxColumnsPerRow = 8,
      overlays = { healPrediction = true, healMineOnly = false, absorbs = true, threat = true,
                   dispelHighlight = true, rangeFade = true },
      icons = { raidTarget = true, leader = true, role = true },
      auras = { buffs = false, debuffs = true, max = 3, size = 14, growth = "LEFT",
        onlyMine = false, hideLong = true, dispellableFirst = true, filter = {} } }),
    boss = frameDefaults({ width = 195, height = 40, spacing = 4, castBar = true,
      offset = { x = 0, y = 0 },
      auras = { buffs = false, debuffs = true, max = 6, size = 16, growth = "RIGHT",
        onlyMine = true, hideLong = false, dispellableFirst = false, filter = {} } }),
  },
  roleOverrides = {},          -- [characterName] = "TANK" | "HEALER" | "DAMAGER"
  layout = { grid = 16, showGrid = false, snap = true },
}

---------------------------------------------------------------------------
-- Table helpers
---------------------------------------------------------------------------
local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepCopy(x) end
  return t
end
DB.Copy = deepCopy

-- Fill missing keys from defaults; drop values whose type no longer matches.
local function fill(dst, defaults)
  for k, dv in pairs(defaults) do
    local v = dst[k]
    if v == nil then
      dst[k] = deepCopy(dv)
    elseif type(dv) == "table" and type(v) == "table" then
      fill(v, dv)
    elseif type(dv) ~= type(v) and dv ~= nil then
      dst[k] = deepCopy(dv)
    end
  end
  return dst
end
DB.Fill = fill

---------------------------------------------------------------------------
-- Migrations: MIGRATIONS[n] upgrades a profile from schema n-1 to n.
---------------------------------------------------------------------------
DB.MIGRATIONS = {
  -- 2: player auras now draw under the player frame; Blizzard's buff bar
  -- already shows them, so start with them off
  [2] = function(profile)
    local a = profile.frames and profile.frames.player and profile.frames.player.auras
    if a then a.buffs, a.debuffs = false, false end
  end,
}

function DB.Migrate(profile, fromSchema)
  local v = tonumber(fromSchema) or 1
  while v < DB.SCHEMA do
    v = v + 1
    local m = DB.MIGRATIONS[v]
    if m then m(profile) end
  end
  profile._schema = DB.SCHEMA
  return profile
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------
local function charKey()
  -- UnitName returns first and last name on this client; GetUnitName(u, true)
  -- gives the full display name. Realm keeps characters on different realms apart.
  local name = (GetUnitName and GetUnitName("player", true)) or UnitName("player") or "?"
  local realm = (GetRealmName and GetRealmName()) or ""
  return name .. " - " .. realm
end
DB.CharKey = charKey

function DB.Init()
  local acct = NyteFramesDB
  local char = NyteFramesCharDB
  if type(acct) ~= "table" or type(acct.profiles) ~= "table" then
    acct = { schema = DB.SCHEMA, profiles = {}, chars = {} }
    -- Account file didn't load: restore the active profile from the backup.
    if type(char) == "table" and type(char.backup) == "table" and char.profileName then
      acct.profiles[char.profileName] = deepCopy(char.backup)
      DB.restoredFromCharacter = true
    end
  end
  acct.chars = acct.chars or {}
  if type(char) ~= "table" then char = {} end
  NyteFramesDB, NyteFramesCharDB = acct, char

  local name = acct.chars[charKey()] or char.profileName or DB.DEFAULT_PROFILE
  DB.Use(name)
  if DB.restoredFromCharacter then
    C_Timer.After(6, function()
      NF.Print("your settings file didn't load (client bug); restored them from this character's backup.")
    end)
  end
end

function DB.Use(name)
  local acct = NyteFramesDB
  local p = acct.profiles[name]
  if type(p) ~= "table" then
    p = {}
    acct.profiles[name] = p
  end
  DB.Migrate(p, p._schema or DB.SCHEMA)
  fill(p, DB.DEFAULTS)
  acct.chars[charKey()] = name
  NyteFramesCharDB.profileName = name
  DB.profile, DB.profileName = p, name
  NF.profile = p
  return p
end

function DB.ProfileName() return DB.profileName or DB.DEFAULT_PROFILE end

-- Sorted profile names.
function DB.List()
  local t = {}
  for name in pairs(NyteFramesDB.profiles) do t[#t + 1] = name end
  table.sort(t, function(a, b) return a:lower() < b:lower() end)
  return t
end

-- Trimmed name, or nil + message. Names must be new unless allowSame matches.
function DB.ValidName(name, allowSame)
  if type(name) ~= "string" then return nil, "type a profile name first." end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil, "type a profile name first." end
  if #name > 32 then return nil, "profile names are 32 characters at most." end
  if NyteFramesDB.profiles[name] and name ~= allowSame then return nil, "a profile named '" .. name .. "' already exists." end
  return name
end

-- Replace a profile's contents in place (keeps the table, so NF.profile stays valid).
function DB.Replace(dst, src)
  for k in pairs(dst) do dst[k] = nil end
  for k, v in pairs(src) do dst[k] = v end
  return dst
end

-- New profile from defaults (source nil) or a copy of another profile.
function DB.Create(name, sourceName)
  local n, err = DB.ValidName(name)
  if not n then return nil, err end
  local src = sourceName and NyteFramesDB.profiles[sourceName]
  if sourceName and type(src) ~= "table" then return nil, "no profile named '" .. tostring(sourceName) .. "'." end
  local p = src and deepCopy(src) or {}
  if src then
    DB.Migrate(p, p._schema or DB.SCHEMA)
  else
    p._schema = DB.SCHEMA
  end
  fill(p, DB.DEFAULTS)
  NyteFramesDB.profiles[n] = p
  return n
end

function DB.Rename(old, new)
  if type(NyteFramesDB.profiles[old]) ~= "table" then return nil, "no profile named '" .. tostring(old) .. "'." end
  local n, err = DB.ValidName(new, old)
  if not n then return nil, err end
  if n == old then return n end
  NyteFramesDB.profiles[n], NyteFramesDB.profiles[old] = NyteFramesDB.profiles[old], nil
  for char, pname in pairs(NyteFramesDB.chars) do
    if pname == old then NyteFramesDB.chars[char] = n end
  end
  if DB.profileName == old then
    DB.profileName = n
    NyteFramesCharDB.profileName = n
  end
  return n
end

function DB.Delete(name)
  if name == DB.profileName then return nil, "that's the profile you're using; switch to another one first." end
  if type(NyteFramesDB.profiles[name]) ~= "table" then return nil, "no profile named '" .. tostring(name) .. "'." end
  NyteFramesDB.profiles[name] = nil
  -- characters that used it fall back to Default next login
  for char, pname in pairs(NyteFramesDB.chars) do
    if pname == name then NyteFramesDB.chars[char] = nil end
  end
  return true
end

-- Back to defaults; role overrides are kept (they're about people, not looks).
function DB.Reset(name)
  local p = NyteFramesDB.profiles[name or DB.profileName]
  if type(p) ~= "table" then return nil, "no profile named '" .. tostring(name) .. "'." end
  local roles = deepCopy(p.roleOverrides or {})
  DB.Replace(p, fill({ _schema = DB.SCHEMA }, DB.DEFAULTS))
  p.roleOverrides = roles
  return true
end

-- After the active profile changed wholesale (switch, import, reset): rescale
-- defaults if needed, re-lay everything out, and offer a reload for the parts
-- that only apply on load (which frames replace Blizzard's).
function DB.Changed(why)
  NF.RunOOC("profile-changed", function()
    if NF.Frames then
      NF.Frames.Calibrate()
      pcall(NF.Frames.Refresh)
      pcall(NF.Frames.UpdateAll)
    end
    if NF.Party then pcall(NF.Party.Apply) end
    if NF.Raid then pcall(NF.Raid.Apply) end
    if NF.Boss then pcall(NF.Boss.Apply) end
    if NF.AuraBridge then pcall(NF.AuraBridge.ScheduleGroup) pcall(NF.AuraBridge.LayoutTarget) end
    if NF.Settings and NF.Settings.RefreshIfShown then NF.Settings.RefreshIfShown() end
    if NF.Blizzard then
      NF.Blizzard.PromptReload("Nyte Frames: settings changed (" .. tostring(why) .. "). Reload the UI so every frame picks them up?")
    end
  end)
end

-- Keep the per-character backup current. Called on logout.
function DB.Backup()
  if NyteFramesCharDB and DB.profile then
    NyteFramesCharDB.backup = deepCopy(DB.profile)
    NyteFramesCharDB.savedAt = time and time() or 0
  end
end

NF.On("PLAYER_LOGOUT", function() DB.Backup() end)
