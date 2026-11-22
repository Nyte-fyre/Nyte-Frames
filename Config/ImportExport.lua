-- ImportExport.lua: exact-settings strings (handoff section 7).
--
--   NYTEFRAMES1:<LibDeflate:EncodeForPrint(CompressDeflate(LibSerialize(payload)))>
--
-- payload = { addon = "NyteFrames", schema = <DB.SCHEMA>, name = <profile name>,
--             profile = <profile table>, hasRoles = <bool> }
--
-- Import never applies partially: the string is decoded, migrated and
-- validated into a complete new profile table first; only then is anything
-- touched, in one swap. DB.DEFAULTS is the reference for every type check.
local _, NF = ...
local L = NF.L
local IE = {}
NF.ImportExport = IE

IE.PREFIX = "NYTEFRAMES"
IE.FORMAT = 1

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)

---------------------------------------------------------------------------
-- Validation rules beyond "same type as the default"
---------------------------------------------------------------------------
local ENUMS = {
  textMode = { percent = true, number = true, both = true },
  nameColor = { class = true, white = true, reaction = true, black = true, gold = true, gray = true },
  growth = { LEFT = true, RIGHT = true, UP = true, DOWN = true },
  dispelMode = { mine = true, all = true },
  dispelColor = { debuff = true, black = true },
}
local RANGES = {
  width = { 10, 2000 }, height = { 4, 1000 }, powerHeightPct = { 0, 100 },
  size = { 4, 100 }, max = { 0, 40 }, maxColumnsPerRow = { 1, 8 },
  fontSize = { 4, 64 }, borderSize = { 1, 4 }, rangeAlpha = { 0, 1 }, grid = { 2, 200 }, spacing = { 0, 100 },
  smallPowerPct = { 0, 100 }, largePowerPct = { 0, 100 },
}
local ROLES = { TANK = true, HEALER = true, DAMAGER = true }
local MAX_STR = 64
local MAX_COORD = 10000

local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end

local function checkLeaf(key, v, dv, path)
  if type(v) ~= type(dv) then
    return "'" .. path .. "' should be a " .. type(dv) .. ", got a " .. type(v)
  end
  if type(v) == "number" then
    if not finite(v) then return "'" .. path .. "' is not a valid number" end
    local r = RANGES[key]
    if r and (v < r[1] or v > r[2]) then
      return "'" .. path .. "' = " .. v .. " is outside " .. r[1] .. "-" .. r[2]
    end
  elseif type(v) == "string" then
    if #v > MAX_STR then return "'" .. path .. "' is too long" end
    if ENUMS[key] and not ENUMS[key][v] then return "'" .. path .. "' has unknown value '" .. v .. "'" end
  end
  return nil
end

-- Keys that are valid but absent from DEFAULTS (nil by default).
local function checkPos(v, path)
  if type(v) ~= "table" then return nil, "'" .. path .. "' should be a table" end
  local out = { point = "CENTER", relPoint = "CENTER" }
  for _, k in ipairs({ "x", "y" }) do
    if not finite(v[k]) or math.abs(v[k]) > MAX_COORD then return nil, "'" .. path .. "." .. k .. "' is not a valid coordinate" end
    out[k] = v[k]
  end
  return out
end

local function checkFreeMap(v, path, valueOk)
  if type(v) ~= "table" then return nil, "'" .. path .. "' should be a table" end
  local out, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 200 then return nil, "'" .. path .. "' has too many entries" end
    local kt = type(k)
    if (kt ~= "string" and kt ~= "number") or (kt == "string" and #k > MAX_STR) or not valueOk(x) then
      return nil, "'" .. path .. "' has a bad entry"
    end
    out[k] = x
  end
  return out
end

local function plainValue(x)
  local t = type(x)
  return t == "boolean" or (t == "number" and finite(x)) or (t == "string" and #x <= MAX_STR)
end
local function roleValue(x) return ROLES[x] == true end

-- Walk v against the default table d. Returns a clean copy (only known keys)
-- or nil + message. `dropped` counts unknown keys that were ignored.
local function walk(v, d, path, dropped, extra)
  if type(v) ~= "table" then return nil, "'" .. (path ~= "" and path or "profile") .. "' should be a table" end
  local out = {}
  for k, x in pairs(v) do
    local p = (path == "" and "" or path .. ".") .. tostring(k)
    local dv = nil
    if type(k) == "string" then dv = d[k] end
    if extra and extra[k] then
      local clean, err = extra[k](x, p)
      if err then return nil, err end
      out[k] = clean
    elseif dv == nil then
      dropped.n = dropped.n + 1
    elseif type(dv) == "table" then
      local clean, err
      if k == "filter" then
        clean, err = checkFreeMap(x, p, plainValue)
      elseif k == "roleOverrides" then
        clean, err = checkFreeMap(x, p, roleValue)
      else
        clean, err = walk(x, dv, p, dropped, nil)
      end
      if err then return nil, err end
      out[k] = clean
    else
      local err = checkLeaf(k, x, dv, p)
      if err then return nil, err end
      out[k] = x
    end
  end
  return out
end

local FRAME_EXTRA = {
  pos = checkPos,
  textMode = function(x, p)
    if ENUMS.textMode[x] then return x end
    return nil, "'" .. p .. "' has unknown value '" .. tostring(x) .. "'"
  end,
}
local ROOT_EXTRA = {
  calibrated = function(x, p) if type(x) == "boolean" then return x end return nil, "'" .. p .. "' should be a boolean" end,
  _schema = function(x) return x end, -- replaced after migration anyway
}

-- Validate a whole profile. Returns a complete, filled profile or nil + message.
function IE.ValidateProfile(profile)
  local D = NF.DB.DEFAULTS
  local dropped = { n = 0 }
  if type(profile) ~= "table" then return nil, "the settings are missing" end
  -- frames: each known frame validated with its own default + pos/textMode
  local frames = profile.frames
  local copy = {}
  for k, x in pairs(profile) do if k ~= "frames" then copy[k] = x end end
  local out, err = walk(copy, D, "", dropped, ROOT_EXTRA)
  if not out then return nil, err end
  out.frames = {}
  if frames ~= nil then
    if type(frames) ~= "table" then return nil, "'frames' should be a table" end
    for key, f in pairs(frames) do
      local df = type(key) == "string" and D.frames[key]
      if df then
        local clean, ferr = walk(f, df, "frames." .. key, dropped, FRAME_EXTRA)
        if not clean then return nil, ferr end
        out.frames[key] = clean
      else
        dropped.n = dropped.n + 1
      end
    end
  end
  NF.DB.Fill(out, D)
  out.calibrated = true -- exported sizes are real UI sizes, never rescale them
  out._schema = NF.DB.SCHEMA
  return out, nil, dropped.n
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------
function IE.Export(includeRoles, profile, name)
  if not (LibSerialize and LibDeflate) then return nil, "LibSerialize/LibDeflate missing" end
  local p = NF.DB.Copy(profile or NF.profile)
  if not includeRoles then p.roleOverrides = {} end
  p.calibrated = true
  p._schema = NF.DB.SCHEMA
  local payload = {
    addon = "NyteFrames", schema = NF.DB.SCHEMA, version = NF.VERSION,
    name = name or NF.DB.ProfileName(), profile = p, hasRoles = includeRoles and true or false,
  }
  local data = LibSerialize:Serialize(payload)
  local packed = LibDeflate:CompressDeflate(data, { level = 9 })
  return IE.PREFIX .. IE.FORMAT .. ":" .. LibDeflate:EncodeForPrint(packed)
end

---------------------------------------------------------------------------
-- Import: decode + validate. Returns a result table or nil + message.
---------------------------------------------------------------------------
function IE.Decode(str)
  if not (LibSerialize and LibDeflate) then return nil, "LibSerialize/LibDeflate missing" end
  if type(str) ~= "string" then return nil, L["paste a Nyte Frames string first"] end
  str = str:gsub("%s+", "")
  if str == "" then return nil, L["paste a Nyte Frames string first"] end
  local fmt, body = str:match("^" .. IE.PREFIX .. "(%d+):(.+)$")
  if not fmt then return nil, L["this isn't a Nyte Frames string (it should start with %s)"]:format(IE.PREFIX .. IE.FORMAT .. ":") end
  if tonumber(fmt) ~= IE.FORMAT then
    return nil, L["this string uses format %s; this version of Nyte Frames reads format %s. Update the addon."]:format(tostring(fmt), tostring(IE.FORMAT))
  end
  local packed = LibDeflate:DecodeForPrint(body)
  if not packed then return nil, L["the string is damaged (couldn't decode it). Copy it again in full."] end
  local data = LibDeflate:DecompressDeflate(packed)
  if not data then return nil, L["the string is damaged (couldn't unpack it). Copy it again in full."] end
  local ok, payload = LibSerialize:Deserialize(data)
  if not ok or type(payload) ~= "table" then return nil, L["the string is damaged (couldn't read the settings)."] end
  if payload.addon ~= "NyteFrames" then return nil, L["this string isn't from Nyte Frames."] end
  local schema = payload.schema
  if not finite(schema) or schema < 1 then return nil, L["the string has no valid settings version."] end
  if schema > NF.DB.SCHEMA then
    return nil, L["these settings come from a newer Nyte Frames (settings v%s). Update the addon first."]:format(tostring(schema))
  end
  if type(payload.profile) ~= "table" then return nil, L["the string has no settings in it."] end
  local profile = NF.DB.Copy(payload.profile)
  local mok, merr = pcall(NF.DB.Migrate, profile, schema)
  if not mok then return nil, L["couldn't upgrade these older settings: %s"]:format(tostring(merr)) end
  local clean, err, dropped = IE.ValidateProfile(profile)
  if not clean then return nil, L["invalid settings: %s"]:format(tostring(err)) end
  local name = type(payload.name) == "string" and payload.name:sub(1, 32) or nil
  return {
    profile = clean, name = name, schema = schema, dropped = dropped or 0,
    hasRoles = payload.hasRoles == true, version = type(payload.version) == "string" and payload.version or "?",
  }
end

---------------------------------------------------------------------------
-- Preview: what would change versus a profile (default: the active one)
---------------------------------------------------------------------------
local SECTION_LABELS = {
  general = L["general"], layout = L["layout"], roleOverrides = L["role overrides"],
  player = L["player"], target = L["target"], targettarget = L["ToT"], targettargettarget = L["ToToT"],
  focus = L["focus"], pet = L["pet"], party = L["party"], raid = L["raid"], boss = L["boss"],
}

local function countDiff(a, b)
  if type(a) == "table" and type(b) == "table" then
    local n, seen = 0, {}
    for k, v in pairs(a) do seen[k] = true n = n + countDiff(v, b[k]) end
    for k, v in pairs(b) do if not seen[k] then n = n + countDiff(nil, v) end end
    return n
  end
  if type(a) == "table" then return countDiff(a, {}) end
  if type(b) == "table" then return countDiff({}, b) end
  return a == b and 0 or 1
end

function IE.Diff(result, against)
  against = against or NF.profile
  local new = result.profile
  local parts, total = {}, 0
  local function add(key, n)
    if n > 0 then
      total = total + n
      parts[#parts + 1] = (SECTION_LABELS[key] or key) .. " " .. n
    end
  end
  add("general", countDiff(new.general, against.general))
  add("layout", countDiff(new.layout, against.layout))
  for _, key in ipairs({ "player", "target", "targettarget", "targettargettarget", "focus", "pet", "party", "raid", "boss" }) do
    add(key, countDiff(new.frames[key], against.frames[key]))
  end
  if result.hasRoles then add("roleOverrides", countDiff(new.roleOverrides, against.roleOverrides)) end
  return total, parts
end

function IE.Summary(result)
  local lines = {}
  lines[1] = "|cff8be28b" .. L["Valid."] .. "|r " .. (result.schema < NF.DB.SCHEMA
    and L["'%s' from Nyte Frames %s (settings v%s, upgraded)."] or L["'%s' from Nyte Frames %s (settings v%s)."])
    :format(result.name or "?", tostring(result.version), tostring(result.schema))
  local on = {}
  for _, key in ipairs({ "player", "target", "targettarget", "targettargettarget", "party", "raid", "boss", "focus", "pet" }) do
    if result.profile.frames[key].enabled then on[#on + 1] = SECTION_LABELS[key] end
  end
  lines[2] = L["Frames on: %s"]:format(table.concat(on, ", "))
  local total, parts = IE.Diff(result)
  if total == 0 then
    lines[3] = L["Same as your current profile."]
  else
    lines[3] = L["%d change(s) vs '%s': %s"]:format(total, NF.DB.ProfileName(), table.concat(parts, ", "))
  end
  local roles = 0
  for _ in pairs(result.profile.roleOverrides) do roles = roles + 1 end
  lines[4] = result.hasRoles and L["%d role override(s) included."]:format(roles) or L["No role overrides (yours are kept)."]
  if result.dropped > 0 then lines[4] = lines[4] .. " " .. L["%d unknown setting(s) ignored."]:format(result.dropped) end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Apply: one swap, after everything validated.
--   mode "current": replace the active profile's contents
--   mode "new":     store as a new profile and switch to it
---------------------------------------------------------------------------
function IE.Apply(result, mode, newName)
  if InCombatLockdown() then return false, L["can't change settings in combat."] end
  if type(result) ~= "table" or type(result.profile) ~= "table" then return false, L["check the string first."] end
  local p = NF.DB.Copy(result.profile)
  if mode == "new" then
    local name, err = NF.DB.ValidName(newName)
    if not name then return false, err end
    if not result.hasRoles then p.roleOverrides = NF.DB.Copy(NF.profile.roleOverrides) end
    NyteFramesDB.profiles[name] = p
    NF.DB.Use(name)
  else
    if not result.hasRoles then p.roleOverrides = NF.DB.Copy(NF.profile.roleOverrides) end
    NF.DB.Replace(NF.profile, p)
  end
  NF.DB.Changed("import")
  return true
end
