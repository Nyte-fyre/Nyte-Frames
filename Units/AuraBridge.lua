-- AuraBridge.lua: show Blizzard's own aura icons on Nyte frames.
--
-- Addon code can't read auras in combat on this client (every aura API
-- throws "secret while tainted"). Blizzard's frames still can. So the
-- Blizzard frames are kept running but invisible (Blizzard.lua "ghost"), and
-- their aura icons are re-parented onto our frames:
--   party/raid: CompactUnitFrame .buffFrames / .debuffFrames / .dispelDebuffFrames
--   target:     TargetFrame's aura buttons, re-anchored after every Blizzard update
--
-- Rules that keep this taint-free: never write fields into Blizzard tables
-- (our bookkeeping lives in local weak tables), only call frame methods;
-- party/raid re-mapping happens out of combat; the target hook only moves
-- non-protected aura buttons.
local _, NF = ...
local AB = {}
NF.AuraBridge = AB

local Plain = NF.Compat.Plain
local home = setmetatable({}, { __mode = "k" })    -- icon -> Blizzard frame it came from
local owner = setmetatable({}, { __mode = "k" })   -- icon -> our button it sits on
AB.stats = {}

local function enabled() return NF.profile.general.blizzardAuras end

---------------------------------------------------------------------------
-- Party / raid: Blizzard compact frames
---------------------------------------------------------------------------
function AB.CompactFrames()
  local list = {}
  local function add(f) if f and type(f) == "table" then list[#list + 1] = f end end
  for i = 1, 5 do add(_G["CompactPartyFrameMember" .. i]) end
  for i = 1, 40 do add(_G["CompactRaidFrame" .. i]) end
  for g = 1, 8 do
    for m = 1, 5 do add(_G["CompactRaidGroup" .. g .. "Member" .. m]) end
  end
  return list
end

local function iconLists(f)
  return {
    debuff = rawget(f, "debuffFrames"),
    buff = rawget(f, "buffFrames"),
    dispel = rawget(f, "dispelDebuffFrames"),
  }
end

-- Put a row of icons on button b. kind: "debuff" bottom-left growing right,
-- "buff" bottom-right growing left, "dispel" top-right growing left.
local function placeRow(b, icons, kind, maxShown, size)
  local n = 0
  for _, icon in ipairs(icons or {}) do
    n = n + 1
    if n <= maxShown then
      if owner[icon] ~= b then
        home[icon] = home[icon] or icon:GetParent()
        icon:SetParent(b.textLayer)
        owner[icon] = b
      end
      icon:SetFrameLevel(b.textLayer:GetFrameLevel() + 2)
      icon:SetSize(size, size)
      icon:ClearAllPoints()
      local off = (n - 1) * (size + 1)
      if kind == "debuff" then
        icon:SetPoint("BOTTOMLEFT", b.health, "BOTTOMLEFT", 2 + off, 2)
      elseif kind == "buff" then
        icon:SetPoint("BOTTOMRIGHT", b.health, "BOTTOMRIGHT", -2 - off, 2)
      else
        icon:SetPoint("TOPRIGHT", b.health, "TOPRIGHT", -16 - off, -2)
      end
    else
      -- more icons than wanted: park them where they can't be seen
      icon:SetParent(NF.Blizzard.hiddenParent)
      owner[icon] = nil
    end
  end
end

local function release(icon)
  if home[icon] then icon:SetParent(home[icon]) end
  owner[icon] = nil
end

-- Our buttons by unit token (party + raid)
local function ourButtons()
  local map = {}
  for _, list in ipairs({ NF.Party and NF.Party.buttons or {}, NF.Raid and NF.Raid.buttons or {} }) do
    for _, b in ipairs(list) do
      local placed = (NF.Party.placed[b] or (NF.Raid and NF.Raid.placed[b]))
      if placed and b.unit then map[b.unit] = b end
    end
  end
  return map
end

function AB.MapGroup()
  if not enabled() then return end
  NF.RunOOC("aurabridge-group", function()
    local ours = ourButtons()
    local frames = AB.CompactFrames()
    local s = { compactFrames = #frames, mapped = 0, icons = 0, missingLists = 0 }
    -- first give every icon back, then hand out again
    for icon in pairs(owner) do release(icon) end
    for _, f in ipairs(frames) do
      pcall(f.EnableMouse, f, false) -- invisible Blizzard frames must not eat clicks
      local unit = Plain(rawget(f, "unit"))
      local b = type(unit) == "string" and ours[unit]
      local lists = iconLists(f)
      if not (lists.debuff or lists.buff) then s.missingLists = s.missingLists + 1 end
      if b then
        local c = NF.profile.frames[b.key].auras
        local size = c.size or 14
        local maxN = c.max or 3
        placeRow(b, lists.debuff, "debuff", c.debuffs and maxN or 0, size)
        placeRow(b, lists.buff, "buff", c.buffs and maxN or 0, size)
        placeRow(b, lists.dispel, "dispel", NF.profile.frames[b.key].overlays.dispelHighlight and 3 or 0, size)
        s.mapped = s.mapped + 1
      end
    end
    for _ in pairs(owner) do s.icons = s.icons + 1 end
    AB.stats.group = s
  end)
end

-- Blizzard re-lays its compact frames on roster/option changes: follow it.
local scheduled
function AB.ScheduleGroup()
  if scheduled or not enabled() then return end
  scheduled = true
  C_Timer.After(0.5, function()
    scheduled = false
    AB.MapGroup()
  end)
end

---------------------------------------------------------------------------
-- Target: Blizzard's target-frame aura buttons
---------------------------------------------------------------------------
local function targetButtons()
  local tf = _G.TargetFrame
  local pools = tf and rawget(tf, "auraPools")
  local buffs, debuffs = {}, {}
  if not pools then return buffs, debuffs, false end
  local function collect(template, into)
    local ok, iter, st, ctl = pcall(pools.EnumerateActiveByTemplate, pools, template)
    if not ok or type(iter) ~= "function" then return false end
    for frame in iter, st, ctl do into[#into + 1] = frame end
    return true
  end
  local okB = collect("TargetBuffFrameTemplate", buffs)
  local okD = collect("TargetDebuffFrameTemplate", debuffs)
  if not okB and not okD then
    local ok, iter, st, ctl = pcall(pools.EnumerateActive, pools)
    if ok and type(iter) == "function" then
      for frame in iter, st, ctl do buffs[#buffs + 1] = frame end
    end
  end
  return buffs, debuffs, true
end

-- Rows under the target frame: buffs first, debuffs on the next row.
function AB.LayoutTarget()
  if not enabled() then return end
  local b = NF.Frames and NF.Frames.byKey.target
  if not b then return end
  local c = NF.profile.frames.target.auras
  local size, maxN = c.size or 20, c.max or 16
  local perRow = math.max(1, math.floor((NF.profile.frames.target.width + 1) / (size + 1)))
  local buffs, debuffs, found = targetButtons()
  AB.stats.target = { found = found, buffs = #buffs, debuffs = #debuffs }
  local row = 0
  local function lay(list, show)
    local n = 0
    for _, icon in ipairs(list) do
      n = n + 1
      if show and n <= maxN then
        icon:SetParent(b)
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        local col = (n - 1) % perRow
        local r = row + math.floor((n - 1) / perRow)
        icon:SetPoint("TOPLEFT", b, "BOTTOMLEFT", col * (size + 1), -2 - r * (size + 1) - (b.castBarSpace or 0))
      else
        icon:SetParent(NF.Blizzard.hiddenParent)
      end
    end
    if show and n > 0 then row = row + math.ceil(math.min(n, maxN) / perRow) end
  end
  lay(buffs, c.buffs)
  lay(debuffs, c.debuffs)
end

---------------------------------------------------------------------------
function AB.Init()
  if not enabled() then return end
  -- group: follow Blizzard's own layout passes and our re-sorts
  for _, fn in ipairs({ "CompactUnitFrame_SetUnit", "DefaultCompactUnitFrameSetup",
      "CompactUnitFrame_UpdateAll" }) do
    if type(_G[fn]) == "function" then
      hooksecurefunc(fn, function() AB.ScheduleGroup() end)
      AB.stats.hooks = (AB.stats.hooks or 0) + 1
    end
  end
  NF.On("GROUP_ROSTER_UPDATE", AB.ScheduleGroup)
  NF.On("PLAYER_REGEN_ENABLED", AB.ScheduleGroup)
  -- target: re-anchor after each Blizzard aura update
  local tf = _G.TargetFrame
  if tf and type(tf.UpdateAuras) == "function" then
    hooksecurefunc(tf, "UpdateAuras", function()
      local ok, err = pcall(AB.LayoutTarget)
      if not ok then NF.Error("aura bridge target", err) end
    end)
    AB.stats.targetHook = true
  elseif type(_G.TargetFrame_UpdateAuras) == "function" then
    hooksecurefunc("TargetFrame_UpdateAuras", function()
      local ok, err = pcall(AB.LayoutTarget)
      if not ok then NF.Error("aura bridge target", err) end
    end)
    AB.stats.targetHook = "global"
  end
  NF.On("PLAYER_TARGET_CHANGED", function() pcall(AB.LayoutTarget) end)
  NF.On("PLAYER_LOGOUT", function()
    if NyteFramesProbeDB then NyteFramesProbeDB.auraBridge = { stats = NF.DB.Copy(AB.stats), at = time() } end
  end)
  AB.ScheduleGroup()
end

-- /nf auras: what the bridge found
function AB.Report()
  local g, t = AB.stats.group or {}, AB.stats.target or {}
  NF.Print(string.format("aura bridge %s. Group: %d Blizzard frames, %d mapped to ours, %d icons moved%s. Target hook: %s, last update %d buffs / %d debuffs%s.",
    enabled() and "on" or "off", g.compactFrames or 0, g.mapped or 0, g.icons or 0,
    (g.missingLists or 0) > 0 and (", " .. g.missingLists .. " frames without icon lists") or "",
    tostring(AB.stats.targetHook or "missing"), t.buffs or 0, t.debuffs or 0,
    (t.found == false) and " (no aura pools found)" or ""))
  if IsInGroup() and not IsInRaid() and (g.compactFrames or 0) == 0 then
    print("  No Blizzard party frames to borrow from: turn on 'Raid-Style Party Frames' in Blizzard's Edit Mode.")
  end
  if NyteFramesProbeDB then NyteFramesProbeDB.auraBridge = { stats = NF.DB.Copy(AB.stats), at = time() } end
end
