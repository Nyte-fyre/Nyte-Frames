-- AuraBridge.lua: Blizzard draws the aura icons on Nyte frames.
--
-- Addon code can't read auras in combat on this client (every aura API
-- throws "secret while tainted"). Blizzard's own raid frames don't read them
-- in Lua either: they register a *container* aura anchor
--   C_UnitAuras.AddPrivateAuraAnchor({ isContainer = true, parent = frame, ... })
-- and Blizzard_PrivateAurasUI (secure) then draws buffs, debuffs, the dispel
-- overlay and big defensives on that parent, reading its layout from the
-- parent's attributes ("max-buffs", "debuff-size", ...). The API has no
-- addon restriction, so Nyte Frames registers the same kind of anchor with
-- its own frames as the parent:
--   party/raid: the unit button itself (same shape as Blizzard's raid frames)
--   player/target: a strip under the frame (under the cast bar)
-- Secure buttons only take attributes out of combat, so group anchors are
-- (re)made out of combat, when the button's unit changes.
local _, NF = ...
local AB = {}
NF.AuraBridge = AB

local Plain, Try = NF.Compat.Plain, NF.Compat.Try
AB.stats = { anchors = 0, failed = 0 }
local anchors = {}   -- [holder frame] = { id = anchorID, unit = token }
local strips = {}    -- [frame key] = strip frame
local settingsTick = 0

local function enabled()
  return NF.profile.general.blizzardAuras and C_UnitAuras and C_UnitAuras.AddPrivateAuraAnchor ~= nil
end

-- Every attribute Blizzard_PrivateAurasUI reads from a container's parent.
AB.ATTRS = {
  "max-buffs", "max-debuffs", "max-dispel-debuffs", "aura-organization-type",
  "always-hide-duration", "set-aura-size-to-icon-size", "display-larger-role-specific-debuffs",
  "dispel-indicator-overlay-type", "dispel-indicator-overlay-animation",
  "dispel-indicator-animated-border", "show-big-defensive", "big-defensive-size",
  "power-bar-used-height", "group-type", "display-only-dispellable-debuffs",
  "ignore-buffs", "ignore-debuffs", "ignore-dispel-debuffs", "dispel-indicator-option",
  "debuff-size", "buff-size", "debuff-border-scale", "buff-border-scale",
}

-- Blizzard's current settings, copied from one of its live raid-style frames
-- (it exists even solo: the player's own party frame), so our icons follow
-- the user's Blizzard raid-frame options unless we override them.
local template
function AB.Template()
  if template then return template end
  local t = {}
  for _, name in ipairs({ "CompactPartyFrameMember1", "CompactRaidFrame1", "CompactRaidGroup1Member1" }) do
    local f = _G[name]
    if f and f.GetAttribute then
      for _, a in ipairs(AB.ATTRS) do
        local v = Plain(Try(f.GetAttribute, f, a))
        if v ~= nil and t[a] == nil then t[a] = v end
      end
    end
  end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  AB.stats.templateAttrs = n
  if n > 0 then template = t end
  return t
end

-- Our settings on top of Blizzard's
local function settingsFor(key)
  local c = NF.profile.frames[key]
  local a = {}
  for k, v in pairs(AB.Template()) do a[k] = v end
  local size = c.auras.size or 14
  local maxN = c.auras.max or 3
  a["max-buffs"] = c.auras.buffs and maxN or 0
  a["max-debuffs"] = c.auras.debuffs and maxN or 0
  a["ignore-buffs"] = not c.auras.buffs
  a["ignore-debuffs"] = not c.auras.debuffs
  a["max-dispel-debuffs"] = c.overlays.dispelHighlight and 3 or 0
  a["ignore-dispel-debuffs"] = not c.overlays.dispelHighlight
  a["debuff-size"] = size
  a["buff-size"] = size
  a["debuff-border-scale"] = a["debuff-border-scale"] or 1
  a["buff-border-scale"] = a["buff-border-scale"] or 1
  a["power-bar-used-height"] = 0
  return a, size
end

local function applySettings(holder, key)
  local a, size = settingsFor(key)
  for k, v in pairs(a) do pcall(holder.SetAttribute, holder, k, v) end
  settingsTick = settingsTick + 1
  pcall(holder.SetAttribute, holder, "update-settings", settingsTick)
  return size
end

local function removeAnchor(holder)
  local a = anchors[holder]
  if a and a.id then pcall(C_UnitAuras.RemovePrivateAuraAnchor, a.id) end
  anchors[holder] = nil
end

-- Register (or refresh) a container anchor: holder shows unit's auras.
function AB.Attach(holder, unit, key)
  if not enabled() then return end
  local size = applySettings(holder, key)
  local a = anchors[holder]
  if a and a.unit == unit and a.id then return end
  removeAnchor(holder)
  local ok, id = pcall(C_UnitAuras.AddPrivateAuraAnchor, {
    unitToken = unit, auraIndex = 1, parent = holder,
    showCooldownFrame = true, showCooldownEdge = false, showCountdownNumbers = false,
    showDispelIcon = false, isContainer = true,
    iconInfo = {
      iconAnchor = { point = "BOTTOMLEFT", relativeTo = holder, relativePoint = "BOTTOMLEFT", offsetX = 0, offsetY = 0 },
      iconWidth = size, iconHeight = size, borderScale = 1,
    },
  })
  if ok and id then
    anchors[holder] = { id = id, unit = unit }
    AB.stats.anchors = AB.stats.anchors + 1
  else
    AB.stats.failed = AB.stats.failed + 1
    AB.stats.lastError = ok and "no anchor id returned" or tostring(id):sub(1, 200)
  end
end

function AB.Detach(holder) removeAnchor(holder) end

---------------------------------------------------------------------------
-- Party / raid: the buttons themselves are the holders (secure: OOC only)
---------------------------------------------------------------------------
function AB.MapGroup()
  if not enabled() then return end
  NF.RunOOC("aurabridge-group", function()
    for _, mod in ipairs({ NF.Party, NF.Raid }) do
      for _, b in ipairs(mod and mod.buttons or {}) do
        if mod.placed[b] then AB.Attach(b, b.unit, b.key) else removeAnchor(b) end
      end
    end
  end)
end

local scheduled
function AB.ScheduleGroup()
  if scheduled or not enabled() then return end
  scheduled = true
  C_Timer.After(0.2, function()
    scheduled = false
    AB.MapGroup()
  end)
end

---------------------------------------------------------------------------
-- Player / target: a strip under the frame (plain frame, any time)
---------------------------------------------------------------------------
local STRIP_KEYS = { "player", "target" }

local function layoutStrip(key)
  local b = NF.Frames and NF.Frames.byKey[key]
  if not b then return end
  local c = NF.profile.frames[key]
  local want = c.auras.buffs or c.auras.debuffs
  local strip = strips[key]
  if not want then
    if strip then removeAnchor(strip) strip:Hide() end
    return
  end
  if not strip then
    strip = CreateFrame("Frame", nil, b)
    strips[key] = strip
  end
  local size = c.auras.size or 20
  strip:ClearAllPoints()
  strip:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2 - (b.castBarSpace or 0))
  strip:SetSize(c.width, size * 2 + 2)
  strip:Show()
  AB.Attach(strip, key, key)
end

function AB.LayoutTarget()
  if not enabled() then return end
  for _, key in ipairs(STRIP_KEYS) do layoutStrip(key) end
end

-- Blizzard's container only re-reads a token's auras on UNIT_AURA, combat
-- start/end or an "update-settings" change; it ignores target swaps, so the
-- old target's icons stayed. A new "update-settings" value forces a re-read
-- of whoever "target" is now (plain frame: fine in combat).
function AB.RefreshStrip(key)
  local strip = strips[key]
  if not (strip and anchors[strip]) then return end
  settingsTick = settingsTick + 1
  pcall(strip.SetAttribute, strip, "update-settings", settingsTick)
  AB.stats.refreshes = (AB.stats.refreshes or 0) + 1
end
NF.On("PLAYER_TARGET_CHANGED", function() if NF.profile and enabled() then AB.RefreshStrip("target") end end)

---------------------------------------------------------------------------
function AB.Init()
  if not enabled() then
    AB.stats.disabled = NF.profile.general.blizzardAuras and "AddPrivateAuraAnchor missing" or "off in settings"
    return
  end
  AB.LayoutTarget()
  AB.ScheduleGroup()
  NF.On("PLAYER_LOGOUT", function()
    if NyteFramesProbeDB then NyteFramesProbeDB.auraBridge = { stats = NF.DB.Copy(AB.stats), at = time() } end
  end)
end

-- /nf auras: what the bridge did
function AB.Report()
  local s = AB.stats
  local live = 0
  for _ in pairs(anchors) do live = live + 1 end
  NF.Print(string.format("Blizzard aura display %s. %d anchors live (%d made, %d failed), %s Blizzard settings copied.%s",
    enabled() and "on" or ("off: " .. tostring(s.disabled or "")), live, s.anchors or 0, s.failed or 0,
    tostring(s.templateAttrs or 0), s.lastError and (" Last error: " .. s.lastError) or ""))
  if NyteFramesProbeDB then NyteFramesProbeDB.auraBridge = { stats = NF.DB.Copy(s), live = live, at = time() } end
end

---------------------------------------------------------------------------
-- /nf auras dump: record how this client's Blizzard frames hold their aura
-- icons (key names, object types, children), so the bridge can be pointed
-- at the right parts. Only names and types are stored, never values.
---------------------------------------------------------------------------
local PATTERN = { "aura", "buff", "debuff", "dispel", "pool", "icon", "container" }
local function interesting(k)
  if type(k) ~= "string" then return false end
  local l = k:lower()
  for _, p in ipairs(PATTERN) do if l:find(p, 1, true) then return true end end
  return false
end

local function describe(v)
  local t = type(v)
  if t == "table" then
    if type(rawget(v, 0)) == "userdata" and v.GetObjectType then
      local ok, ot = pcall(v.GetObjectType, v)
      local okS, shown = pcall(v.IsShown, v)
      local okN, name = pcall(v.GetName, v)
      return (ok and ot or "frame") .. (okN and name and (" " .. name) or "") .. ((okS and shown) and " shown" or "")
    end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return "table[" .. n .. "]"
  end
  return t
end

local function scan(obj, path, depth, out, seen)
  if depth < 0 or type(obj) ~= "table" or seen[obj] or #out > 400 then return end
  seen[obj] = true
  for k, v in pairs(obj) do
    if interesting(k) then out[#out + 1] = path .. "." .. tostring(k) .. " = " .. describe(v) end
    if type(v) == "table" and type(k) == "string" and not k:find("^_") then
      scan(v, path .. "." .. k, depth - 1, out, seen)
    elseif type(v) == "table" and type(k) == "number" and k <= 3 then
      scan(v, path .. "[" .. k .. "]", depth - 1, out, seen)
    end
  end
  -- child frames too (icons are often unnamed children)
  if type(rawget(obj, 0)) == "userdata" and obj.GetChildren then
    local kids = { pcall(obj.GetChildren, obj) }
    for i = 2, math.min(#kids, 30) do
      local c = kids[i]
      local okW, w = pcall(c.GetWidth, c)
      out[#out + 1] = path .. ":child" .. (i - 1) .. " = " .. describe(c) ..
        (okW and type(w) == "number" and string.format(" w%.0f", w) or "")
      if depth > 0 then scan(c, path .. ":child" .. (i - 1), depth - 1, out, seen) end
    end
  end
end

function AB.Dump()
  local out = {}
  for _, name in ipairs({ "TargetFrame", "CompactPartyFrameMember1", "CompactPartyFrame",
      "CompactRaidFrame1", "CompactRaidFrameContainer" }) do
    local f = _G[name]
    out[#out + 1] = "== " .. name .. ": " .. (f and describe(f) or "missing")
    if f then
      local keys = {}
      for k, v in pairs(f) do
        if type(k) == "string" then keys[#keys + 1] = k .. "=" .. type(v) end
      end
      table.sort(keys)
      out[#out + 1] = "keys: " .. table.concat(keys, ", "):sub(1, 3000)
      local ok, err = pcall(scan, f, name, 3, out, {})
      if not ok then out[#out + 1] = "scan error: " .. tostring(err) end
    end
  end
  local globals = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and type(v) == "function" and (k:find("^CompactUnitFrame_") or k:find("^TargetFrame")
        or k:find("Aura") and k:find("Frame")) then
      globals[#globals + 1] = k
    end
  end
  table.sort(globals)
  out[#out + 1] = "functions: " .. table.concat(globals, ", "):sub(1, 4000)
  NyteFramesProbeDB.auraDump = { at = time(), lines = out }
  NF.Print("aura dump saved (" .. #out .. " lines). /reload so it's written to disk.")
end
