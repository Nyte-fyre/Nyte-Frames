-- Probe.lua: records which unit APIs are readable, secret, missing or erroring
-- on this client, in and out of combat, for every unit token Nyte Frames uses.
--
-- It runs passively for a whole play session and keeps everything (counts,
-- not raw samples), so one session in the open world, a dungeon and a raid
-- answers every design question. Nothing secret is ever stored: only the
-- status string ("ok", "secret", "nil", "err") and, for a few harmless
-- fields, the distinct plain values seen.
--
-- Saved in NyteFramesProbeDB. Read it offline with tests/read_probe.py.
local _, NF = ...
local P = {}
NF.Probe = P

local Compat -- set in Start
local PROBE_VERSION = 1
local MAX_FIGHTS, MAX_EVENTS, MAX_INSPECTS, MAX_ERRORS = 200, 2000, 40, 200
local TICK = 1.5             -- seconds between combat samples
local RAID_PER_TICK = 6      -- raid units sampled per tick (rotating)

local db                     -- NyteFramesProbeDB
local inCombat = false
local fight                  -- current fight record
local ticker

---------------------------------------------------------------------------
-- Classification
---------------------------------------------------------------------------
local function status(ok, v)
  if not ok then return "err" end
  if v == nil then return "nil" end
  if issecretvalue and issecretvalue(v) then return "secret" end
  if type(v) == "table" and issecrettable and issecrettable(v) then return "secrettable" end
  return "ok"
end

local function plainValue(v)
  if v == nil then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  return "<" .. t .. ">"
end

local function context()
  local inst = "none"
  local ok, isIn, instType = pcall(IsInInstance)
  if ok and isIn and type(instType) == "string" and not (issecretvalue and issecretvalue(instType)) then
    inst = instType
  end
  local phase = inCombat and "combat" or "ooc"
  if inCombat and IsEncounterInProgress then
    local ok2, enc = pcall(IsEncounterInProgress)
    if ok2 and enc == true then phase = "encounter" end
  end
  return phase .. "@" .. inst
end

-- agg[ctx][unitClass][field][status] = count
local function count(ctx, unitClass, field, st, okFlag, v, errMsg)
  local a = db.agg[ctx]
  if not a then a = {} db.agg[ctx] = a end
  local u = a[unitClass]
  if not u then u = {} a[unitClass] = u end
  local f = u[field]
  if not f then f = {} u[field] = f end
  f[st] = (f[st] or 0) + 1
  if st == "err" then
    local key = unitClass .. "." .. field
    if not db.errs[key] then db.errs[key] = tostring(errMsg):sub(1, 200) end
  end
end

-- distinct plain values for a few harmless fields
local EXAMPLE_FIELDS = {
  class = true, role = true, powerType = true, reaction = true, threat = true,
  classification = true, level = true, inRangeChecked = true, dead = true,
  connected = true, isPlayer = true, raidTarget = true, castNotInt = true,
  ["roster.subgroup"] = true, ["roster.role"] = true, ["roster.combatRole"] = true,
  ["debuff1.dispelName"] = true, ["buff1.sourceUnit"] = true, ["debuff1.sourceUnit"] = true,
  exists = true, canAttack = true, healthPct = true,
}
local function example(unitClass, field, v)
  if not EXAMPLE_FIELDS[field] then return end
  local pv = plainValue(v)
  if pv == nil then return end
  local key = unitClass .. "." .. field
  local list = db.examples[key]
  if not list then list = {} db.examples[key] = list end
  if #list >= 8 then return end
  for _, x in ipairs(list) do if x == pv then return end end
  list[#list + 1] = pv
end

local function record(ctx, unitClass, field, ok, v)
  local st = status(ok, v)
  count(ctx, unitClass, field, st, ok, v, (not ok) and v or nil)
  if ok then example(unitClass, field, v) end
  return st
end

---------------------------------------------------------------------------
-- Field readers. Each returns the value to classify (first return unless noted).
---------------------------------------------------------------------------
local RANGE_SPELL = {
  PALADIN = "Holy Light", PRIEST = "Lesser Heal", DRUID = "Healing Touch",
  SHAMAN = "Healing Wave", MAGE = "Arcane Intellect", WARLOCK = "Unending Breath",
}
local rangeSpell

local function sel(n, ...) return (select(n, ...)) end

local FIELDS = {
  { "exists", function(u) return UnitExists(u) end },
  { "name", function(u) return UnitName(u) end },
  { "fullName", function(u) return GetUnitName(u, true) end },
  { "guid", function(u) return UnitGUID(u) end },
  { "class", function(u) return sel(2, UnitClass(u)) end },
  { "isPlayer", function(u) return UnitIsPlayer(u) end },
  { "level", function(u) return UnitLevel(u) end },
  { "classification", function(u) return UnitClassification(u) end },
  { "health", function(u) return UnitHealth(u) end },
  { "healthMax", function(u) return UnitHealthMax(u) end },
  { "healthPct", function(u) return UnitHealthPercent(u) end },
  { "healthPct100", function(u) return UnitHealthPercent(u, true, CurveConstants and CurveConstants.ScaleTo100) end },
  { "healthMissing", function(u) return UnitHealthMissing(u) end },
  { "power", function(u) return UnitPower(u) end },
  { "powerMax", function(u) return UnitPowerMax(u) end },
  { "powerType", function(u) return UnitPowerType(u) end },
  { "powerPct", function(u) return UnitPowerPercent(u) end },
  { "dead", function(u) return UnitIsDeadOrGhost(u) end },
  { "ghost", function(u) return UnitIsGhost(u) end },
  { "connected", function(u) return UnitIsConnected(u) end },
  { "reaction", function(u) return UnitReaction(u, "player") end },
  { "canAttack", function(u) return UnitCanAttack("player", u) end },
  { "isUnitPlayer", function(u) return UnitIsUnit(u, "player") end },
  { "role", function(u) return UnitGroupRolesAssigned(u) end },
  { "inRange", function(u) return UnitInRange(u) end },
  { "inRangeChecked", function(u) return sel(2, UnitInRange(u)) end },
  { "spellRange", function(u)
      if not rangeSpell then return nil end
      return C_Spell.IsSpellInRange(rangeSpell, u)
    end },
  { "threat", function(u) return UnitThreatSituation(u) end },
  { "incHeals", function(u) return UnitGetIncomingHeals(u) end },
  { "incHealsMine", function(u) return UnitGetIncomingHeals(u, "player") end },
  { "absorbs", function(u) return UnitGetTotalAbsorbs(u) end },
  { "healAbsorbs", function(u) return UnitGetTotalHealAbsorbs(u) end },
  { "raidTarget", function(u) return GetRaidTargetIndex(u) end },
  { "leader", function(u) return UnitIsGroupLeader(u) end },
  { "phase", function(u) return UnitPhaseReason(u) end },
  { "castName", function(u) return UnitCastingInfo(u) end },
  { "castNotInt", function(u) return sel(8, UnitCastingInfo(u)) end },
  { "castEnd", function(u) return sel(5, UnitCastingInfo(u)) end },
  { "castDuration", function(u) return UnitCastingDuration(u) end },
  { "channelName", function(u) return UnitChannelInfo(u) end },
  { "channelDuration", function(u) return UnitChannelDuration(u) end },
}

local AURA_SUBFIELDS = { "auraInstanceID", "spellId", "name", "icon", "duration",
  "expirationTime", "applications", "dispelName", "sourceUnit", "isFromPlayerOrPlayerPet",
  "isHelpful", "isRaid", "canApplyAura", "isBossAura" }

local AURA_QUERIES = {
  { "buff1", "HELPFUL" },
  { "debuff1", "HARMFUL" },
  { "buffRaid", "HELPFUL|RAID" },
  { "debuffRaid", "HARMFUL|RAID" },
  { "debuffDispel", "HARMFUL|RAID_PLAYER_DISPELLABLE" },
  { "buffMine", "HELPFUL|PLAYER" },
}

local function sampleAuras(ctx, cls, unit)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
  for _, q in ipairs(AURA_QUERIES) do
    local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, 1, q[2])
    local st = record(ctx, cls, q[1], ok, data)
    if st == "ok" and type(data) == "table" and (q[1] == "buff1" or q[1] == "debuff1") then
      for _, k in ipairs(AURA_SUBFIELDS) do
        local okv, v = pcall(function() return data[k] end)
        record(ctx, cls, q[1] .. "." .. k, okv, v)
      end
      -- duration object route for the swipe
      local id = data.auraInstanceID
      if id ~= nil and C_UnitAuras.GetAuraDuration then
        local okd, d = pcall(C_UnitAuras.GetAuraDuration, unit, id)
        record(ctx, cls, q[1] .. ".durationObject", okd, d)
      end
      if id ~= nil and C_UnitAuras.GetAuraApplicationDisplayCount then
        local okc, c = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, id)
        record(ctx, cls, q[1] .. ".displayCount", okc, c)
      end
    end
  end
  if C_UnitAuras.GetUnitAuraInstanceIDs then
    local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, "HARMFUL")
    record(ctx, cls, "auraInstanceIDs", ok, ids)
  end
  if C_UnitAuras.GetUnitAuras then
    local ok, list = pcall(C_UnitAuras.GetUnitAuras, unit, "HARMFUL", 3)
    record(ctx, cls, "getUnitAuras", ok, list)
  end
end

local function sampleUnit(ctx, cls, unit)
  local okE, exists = pcall(UnitExists, unit)
  if not okE then record(ctx, cls, "exists", false, exists) return end
  if issecretvalue and issecretvalue(exists) then record(ctx, cls, "exists", true, exists) return end
  if not exists then return end
  for _, f in ipairs(FIELDS) do
    local ok, v = pcall(f[2], unit)
    record(ctx, cls, f[1], ok, v)
  end
  sampleAuras(ctx, cls, unit)
end

local raidCursor = 0
local function sampleRoster(ctx)
  if not GetRaidRosterInfo then return end
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  if not (IsInRaid and IsInRaid()) or n == 0 then return end
  for i = 1, math.min(n, 3) do
    local ok, name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML, combatRole =
      pcall(GetRaidRosterInfo, i)
    record(ctx, "roster", "roster.call", ok, name)
    if ok then
      record(ctx, "roster", "roster.name", true, name)
      record(ctx, "roster", "roster.subgroup", true, subgroup)
      record(ctx, "roster", "roster.class", true, fileName)
      record(ctx, "roster", "roster.online", true, online)
      record(ctx, "roster", "roster.isDead", true, isDead)
      record(ctx, "roster", "roster.role", true, role)
      record(ctx, "roster", "roster.combatRole", true, combatRole)
    end
  end
end

local FIXED = { "player", "target", "targettarget", "targettargettarget", "focus", "pet", "mouseover" }

function P.Sample()
  if not db or not db.enabled then return end
  local ctx = context()
  for _, u in ipairs(FIXED) do sampleUnit(ctx, u, u) end
  for i = 1, 4 do sampleUnit(ctx, "party", "party" .. i) end
  for i = 1, 4 do sampleUnit(ctx, "partytarget", "party" .. i .. "target") end
  for i = 1, 5 do sampleUnit(ctx, "boss", "boss" .. i) end
  if IsInRaid and IsInRaid() then
    local n = GetNumGroupMembers() or 0
    for _ = 1, math.min(RAID_PER_TICK, n) do
      raidCursor = raidCursor % 40 + 1
      sampleUnit(ctx, "raid", "raid" .. raidCursor)
    end
  end
  sampleRoster(ctx)
  db.samples = (db.samples or 0) + 1
  if fight then
    fight.samples = fight.samples + 1
    P.TrackBosses()
  end
end

---------------------------------------------------------------------------
-- Boss tracking during fights (are boss1-5 present? what names can we read?)
---------------------------------------------------------------------------
function P.TrackBosses()
  if not fight then return end
  for i = 1, 5 do
    local u = "boss" .. i
    local ok, e = pcall(UnitExists, u)
    if ok and e ~= nil and not (issecretvalue and issecretvalue(e)) and e then
      local okn, n = pcall(UnitName, u)
      local label = (okn and plainValue(n)) or (okn and "<secret>") or "<err>"
      fight.boss[u] = label
    end
  end
  -- Without boss tokens: is the target a boss (skull level / worldboss), and is its name readable?
  local okl, lvl = pcall(UnitLevel, "target")
  local okc, cls = pcall(UnitClassification, "target")
  local bossy = (okl and plainValue(lvl) == -1) or (okc and plainValue(cls) == "worldboss")
  if bossy then
    local okn, n = pcall(UnitName, "target")
    local label = (okn and plainValue(n)) or "<secret>"
    if #fight.bossTargets < 10 then
      local seen = false
      for _, x in ipairs(fight.bossTargets) do if x == label then seen = true end end
      if not seen then fight.bossTargets[#fight.bossTargets + 1] = label end
    end
  end
end

---------------------------------------------------------------------------
-- Display tests: can secret values reach bars and text?
---------------------------------------------------------------------------
local testBar, testText, testFrame, testTex
local function displayTests(unit)
  if not testBar then
    testFrame = CreateFrame("Frame", nil, UIParent)
    testFrame:Hide()
    testBar = CreateFrame("StatusBar", nil, testFrame)
    testText = testFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  end
  local r = { unit = unit }
  local function t(name, fn)
    local ok, v = pcall(fn)
    r[name] = ok and (v == nil and "ok" or status(true, v)) or ("err: " .. tostring(v):sub(1, 120))
  end
  t("barMinMaxSecretMax", function() testBar:SetMinMaxValues(0, UnitHealthMax(unit)) end)
  t("barSetValueSecret", function() testBar:SetValue(UnitHealth(unit)) end)
  t("barGetValue", function() return testBar:GetValue() end)
  t("textSetText", function() testText:SetText(UnitHealth(unit)) end)
  t("textFormattedD", function() testText:SetFormattedText("%d", UnitHealth(unit)) end)
  t("textFormattedS", function() testText:SetFormattedText("%s / %s", UnitHealth(unit), UnitHealthMax(unit)) end)
  t("abbreviate", function() return AbbreviateNumbers(UnitHealth(unit)) end)
  t("abbreviateToText", function() testText:SetText(AbbreviateNumbers(UnitHealth(unit))) end)
  t("abbreviateLarge", function() return AbbreviateLargeNumbers(UnitHealth(unit)) end)
  t("breakUpLarge", function() return BreakUpLargeNumbers(UnitHealth(unit)) end)
  t("pctToText", function()
    testText:SetFormattedText("%.0f%%", UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
  end)
  t("pctDefault", function() return UnitHealthPercent(unit) end)
  t("pctScaled", function() return UnitHealthPercent(unit, true, CurveConstants.ScaleTo100) end)
  t("luaFormat", function() return string.format("%d", UnitHealth(unit)) end)
  t("luaArith", function() return UnitHealth(unit) + 0 end)
  t("luaCompare", function() return UnitHealth(unit) > 0 end)
  t("luaConcat", function() return "x" .. UnitHealth(unit) end)
  t("textGetText", function() return testText:GetText() end)
  t("textTruncateWidth", function() testText:SetWidth(40) testText:SetText(UnitName(unit)) return testText:IsTruncated() end)
  t("powerBar", function() testBar:SetMinMaxValues(0, UnitPowerMax(unit)) testBar:SetValue(UnitPower(unit)) end)
  t("absorbBar", function() testBar:SetMinMaxValues(0, UnitHealthMax(unit)) testBar:SetValue(UnitGetTotalAbsorbs(unit)) end)
  t("healPredCalc", function() return CreateUnitHealPredictionCalculator() end)
  t("detailedHealPred", function()
    local calc = CreateUnitHealPredictionCalculator()
    return UnitGetDetailedHealPrediction(unit, "player", calc)
  end)
  t("setAlphaFromBoolean", function() testFrame:SetAlphaFromBoolean(UnitInRange(unit), 1, 0.4) end)
  t("vertexFromBoolean", function()
    testTex = testTex or testFrame:CreateTexture()
    testTex:SetVertexColorFromBoolean(UnitIsDeadOrGhost(unit), CreateColor(1, 0, 0), CreateColor(0, 1, 0))
  end)
  t("timerDuration", function()
    local d = UnitCastingDuration(unit)
    if d then testBar:SetTimerDuration(d) end
    return d
  end)
  t("threatColor", function() return GetThreatStatusColor(UnitThreatSituation(unit) or 0) end)
  t("classColorSecret", function() return C_ClassColor.GetClassColor(sel(2, UnitClass(unit))) end)
  return r
end
P.DisplayTests = displayTests

---------------------------------------------------------------------------
-- Static facts: APIs, templates, Blizzard frames, events
---------------------------------------------------------------------------
local BLIZZARD_FRAMES = {
  "PlayerFrame", "TargetFrame", "TargetFrameToT", "FocusFrame", "FocusFrameToT", "PetFrame",
  "PartyFrame", "PartyMemberFrame1", "CompactPartyFrame", "CompactRaidFrameContainer",
  "CompactRaidFrameManager", "BossTargetFrameContainer", "Boss1TargetFrame",
  "PlayerCastingBarFrame", "CastingBarFrame", "TargetFrameSpellBar", "FocusFrameSpellBar",
  "PetCastingBarFrame", "EditModeManagerFrame", "CompactArenaFrame",
}

local EVENTS = {
  "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "UNIT_TARGETABLE_CHANGED", "ENCOUNTER_START", "ENCOUNTER_END",
  "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER",
  "UNIT_DISPLAYPOWER", "UNIT_HEAL_PREDICTION", "UNIT_ABSORB_AMOUNT_CHANGED",
  "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
  "UNIT_AURA", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START",
  "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTIBLE",
  "UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "UNIT_NAME_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS",
  "UNIT_FACTION", "UNIT_IN_RANGE_UPDATE", "UNIT_PHASE", "UNIT_PET", "UNIT_TARGET",
  "RAID_TARGET_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ROLES_ASSIGNED", "ROLE_CHANGED_INFORM",
  "GROUP_ROSTER_UPDATE", "INSPECT_READY", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED",
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "COMBAT_LOG_EVENT_UNFILTERED",
  "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "ADDON_RESTRICTION_STATE_CHANGED",
  "EDIT_MODE_LAYOUTS_UPDATED", "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED",
}

local function talentBuckets(configID)
  local info = C_Traits.GetConfigInfo(configID)
  if not info or not info.treeIDs then return nil, "no config/treeIDs" end
  local buckets, total, nodes = {}, 0, 0
  for _, treeID in ipairs(info.treeIDs) do
    for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
      local n = C_Traits.GetNodeInfo(configID, nodeID)
      if n then
        nodes = nodes + 1
        local ranks = plainValue(n.ranksPurchased) or 0
        local x = plainValue(n.posX)
        if type(ranks) == "number" and ranks > 0 and type(x) == "number" then
          local b = math.floor(x / 1000)
          buckets[b] = (buckets[b] or 0) + ranks
          total = total + ranks
        end
      end
    end
  end
  return { buckets = buckets, total = total, nodes = nodes }
end

function P.Static()
  local s = { at = time(), probeVersion = PROBE_VERSION }
  local okB, version, build, date, iface = pcall(GetBuildInfo)
  s.build = okB and (tostring(version) .. "." .. tostring(build) .. " (" .. tostring(date) .. ")") or "?"
  s.interface = okB and iface or nil
  s.projectId = WOW_PROJECT_ID
  s.locale = GetLocale and GetLocale()
  s.apis = {}
  for k, v in pairs(Compat.has) do s.apis[k] = v end
  s.globals = {
    CurveConstants = CurveConstants ~= nil,
    ScaleTo100 = CurveConstants ~= nil and CurveConstants.ScaleTo100 ~= nil,
    EnumPowerType = Enum ~= nil and Enum.PowerType ~= nil,
    PowerBarColor = PowerBarColor ~= nil,
    RAID_CLASS_COLORS = RAID_CLASS_COLORS ~= nil,
    DebuffTypeColor = DebuffTypeColor ~= nil,
    ClickCastFrames = type(ClickCastFrames),
    INSPECT_TRAIT_CONFIG_ID = Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID,
    STANDARD_TEXT_FONT = STANDARD_TEXT_FONT,
  }
  s.templates = {}
  for _, tpl in ipairs({ "SecureUnitButtonTemplate", "SecureHandlerStateTemplate",
      "SecureHandlerAttributeTemplate", "SecureHandlerBaseTemplate", "BackdropTemplate",
      "SecureGroupHeaderTemplate", "PingableUnitFrameTemplate" }) do
    local ok, err = pcall(CreateFrame, "Button", nil, nil, tpl)
    s.templates[tpl] = ok and "ok" or tostring(err):sub(1, 120)
  end
  s.frameMethods = {}
  local f = CreateFrame("Frame")
  local sb = CreateFrame("StatusBar")
  local tex = f:CreateTexture()
  s.frameMethods.SetAlphaFromBoolean = f.SetAlphaFromBoolean ~= nil
  s.frameMethods.SetShownFromBoolean = f.SetShownFromBoolean ~= nil
  s.frameMethods.SetVertexColorFromBoolean = tex.SetVertexColorFromBoolean ~= nil
  s.frameMethods.SetTimerDuration = sb.SetTimerDuration ~= nil
  s.frameMethods.SetMinMaxSmoothedValue = sb.SetMinMaxSmoothedValue ~= nil
  s.frameMethods.SetReverseFill = sb.SetReverseFill ~= nil
  s.blizzard = {}
  for _, name in ipairs(BLIZZARD_FRAMES) do
    local fr = _G[name]
    if fr then
      local okp, prot = pcall(fr.IsProtected, fr)
      s.blizzard[name] = "exists" .. ((okp and prot) and ", protected" or "") ..
        ((fr.IsShown and fr:IsShown()) and ", shown" or "")
    else
      s.blizzard[name] = "missing"
    end
  end
  s.events = {}
  local ef = CreateFrame("Frame")
  for _, e in ipairs(EVENTS) do
    local ok = pcall(ef.RegisterEvent, ef, e)
    s.events[e] = ok
  end
  ef:UnregisterAllEvents()
  -- own talent layout: which posX buckets (1000s) hold the three trees
  if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
    local okc, cfg = pcall(C_ClassTalents.GetActiveConfigID)
    if okc and cfg then
      local ok, res, err = pcall(talentBuckets, cfg)
      s.ownTalents = ok and (res or err) or ("err: " .. tostring(res))
    end
  end
  local okc, _, classFile = pcall(UnitClass, "player")
  s.playerClass = okc and classFile or nil
  s.displayPlayer = displayTests("player")
  db.static = s
  return s
end

---------------------------------------------------------------------------
-- Inspect test (role detection chain step 3)
---------------------------------------------------------------------------
local inspectQueue, inspectPending, inspectedGUIDs = {}, nil, {}
local lastInspect = 0

local function queueGroupInspects()
  if inCombat or not CanInspect then return end
  local units = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
  else
    for i = 1, 4 do units[#units + 1] = "party" .. i end
  end
  for _, u in ipairs(units) do
    local okg, g = pcall(UnitGUID, u)
    local guid = okg and plainValue(g)
    local okp, isP = pcall(UnitIsUnit, u, "player")
    if UnitExists(u) and not (okp and isP == true) and guid and not inspectedGUIDs[guid] then
      inspectQueue[#inspectQueue + 1] = u
    end
  end
end

local function nextInspect()
  if inCombat or inspectPending or #db.inspects >= MAX_INSPECTS then return end
  if (GetTime() - lastInspect) < 3 then return end
  local u = table.remove(inspectQueue, 1)
  if not u then return end
  local okc, can = pcall(CanInspect, u)
  if not (okc and can == true) then return end
  local okg, g = pcall(UnitGUID, u)
  inspectPending = { unit = u, guid = okg and plainValue(g), at = GetTime() }
  lastInspect = GetTime()
  local ok, err = pcall(NotifyInspect, u)
  if not ok then
    db.inspects[#db.inspects + 1] = { err = "NotifyInspect: " .. tostring(err):sub(1, 120) }
    inspectPending = nil
  end
end

local function onInspectReady(_, guid)
  local p = inspectPending
  if not p then return end
  inspectPending = nil
  if p.guid then inspectedGUIDs[p.guid] = true end
  local u = p.unit
  local r = { at = time(), unit = u:gsub("%d+$", "N"), delay = GetTime() - p.at }
  r.guidMatches = (p.guid ~= nil and plainValue(guid) == p.guid) or nil
  local okc, _, classFile = pcall(UnitClass, u)
  r.class = okc and plainValue(classFile) or nil
  local oks, spec = pcall(GetInspectSpecialization, u)
  r.spec = oks and plainValue(spec) or ("err/secret")
  r.role = plainValue(select(2, pcall(UnitGroupRolesAssigned, u)))
  local id = Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID or -1
  local ok, res, err = pcall(talentBuckets, id)
  r.talents = ok and (res or err) or ("err: " .. tostring(res):sub(1, 120))
  db.inspects[#db.inspects + 1] = r
  if ClearInspectPlayer then pcall(ClearInspectPlayer) end
end

---------------------------------------------------------------------------
-- Event log
---------------------------------------------------------------------------
local function logEvent(text)
  local ev = db.events
  ev[#ev + 1] = date("%H:%M:%S") .. " " .. text
  if #ev > MAX_EVENTS then table.remove(ev, 1) end
end

local function argText(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if issecretvalue and issecretvalue(v) then
      parts[#parts + 1] = "<secret>"
    else
      parts[#parts + 1] = tostring(v)
    end
  end
  return table.concat(parts, ", ")
end

local function bossTokenText()
  local parts = {}
  for i = 1, 5 do
    local u = "boss" .. i
    local ok, e = pcall(UnitExists, u)
    if ok and e and not (issecretvalue and issecretvalue(e)) then
      local okn, n = pcall(UnitName, u)
      parts[#parts + 1] = u .. "=" .. ((okn and plainValue(n)) or "<secret>")
    end
  end
  return #parts > 0 and table.concat(parts, " ") or "none"
end

local eventCounts -- [event] = { [unitClass] = n } per context, cheap counters
local function unitClassOf(unit)
  if type(unit) ~= "string" or (issecretvalue and issecretvalue(unit)) then return "?" end
  return (unit:gsub("%d+", "N"))
end

local function onUnitEvent(event, unit)
  local ctx = context()
  local c = db.eventCounts[ctx]
  if not c then c = {} db.eventCounts[ctx] = c end
  local e = c[event]
  if not e then e = {} c[event] = e end
  local k = unitClassOf(unit)
  e[k] = (e[k] or 0) + 1
end

---------------------------------------------------------------------------
-- Fights
---------------------------------------------------------------------------
local function startFight()
  inCombat = true
  local okI, name, instType, diffID = pcall(GetInstanceInfo)
  fight = {
    t = time(), start = GetTime(), samples = 0,
    zone = okI and plainValue(name) or "?", inst = okI and plainValue(instType) or "?",
    diff = okI and plainValue(diffID) or nil, boss = {}, bossTargets = {},
    group = IsInRaid() and "raid" or (IsInGroup() and "party" or "solo"),
    size = GetNumGroupMembers and GetNumGroupMembers() or 0,
  }
  logEvent("combat start (" .. fight.zone .. ", " .. fight.group .. ")")
  local display = displayTests("target")
  if not db.displayCombat and UnitExists("target") then db.displayCombat = display end
  if not db.displayCombatParty and UnitExists("party1") then db.displayCombatParty = displayTests("party1") end
  if ticker then ticker:Cancel() end
  ticker = C_Timer.NewTicker(TICK, function()
    local ok, err = pcall(P.Sample)
    if not ok then NF.Error("probe sample", err) end
  end)
  P.Sample()
end

local function endFight()
  inCombat = false
  if ticker then ticker:Cancel() ticker = nil end
  if fight then
    fight.dur = math.floor((GetTime() - fight.start) * 10) / 10
    fight.start = nil
    local f = db.fights
    f[#f + 1] = fight
    if #f > MAX_FIGHTS then table.remove(f, 1) end
    logEvent(string.format("combat end (%.1fs, %d samples)", fight.dur, fight.samples))
    fight = nil
  end
  C_Timer.After(2, function()
    pcall(P.Sample)
    pcall(queueGroupInspects)
  end)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
function P.RecordError(msg)
  if not db then return end
  if #db.errors < MAX_ERRORS then db.errors[#db.errors + 1] = date("%H:%M:%S") .. " " .. msg end
end

local function newDB()
  return { version = PROBE_VERSION, enabled = true, agg = {}, errs = {}, examples = {},
    fights = {}, events = {}, inspects = {}, errors = {}, eventCounts = {}, samples = 0, sessions = {} }
end

function P.Start()
  Compat = NF.Compat
  if type(NyteFramesProbeDB) ~= "table" or NyteFramesProbeDB.version ~= PROBE_VERSION then
    NyteFramesProbeDB = newDB()
  end
  db = NyteFramesProbeDB
  for k, v in pairs(newDB()) do if db[k] == nil then db[k] = v end end
  db.sessions[#db.sessions + 1] = { at = time(), addon = NF.VERSION }
  for _, m in ipairs(NF.errors) do P.RecordError(m) end

  local okc, _, classFile = pcall(UnitClass, "player")
  rangeSpell = okc and RANGE_SPELL[classFile] or nil

  local okS, err = pcall(P.Static)
  if not okS then NF.Error("probe static", err) end

  NF.On("PLAYER_REGEN_DISABLED", function() if db.enabled then startFight() end end)
  NF.On("PLAYER_REGEN_ENABLED", function() if db.enabled or fight then endFight() end end)
  if InCombatLockdown() and db.enabled then startFight() end

  local function logged(event, ...)
    if not db.enabled then return end
    logEvent(event .. "(" .. argText(...) .. ") bosses: " .. bossTokenText())
  end
  for _, e in ipairs({ "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT",
      "PLAYER_ROLES_ASSIGNED", "ROLE_CHANGED_INFORM", "ADDON_RESTRICTION_STATE_CHANGED" }) do
    NF.On(e, logged)
  end
  NF.On("UNIT_TARGETABLE_CHANGED", function(event, unit)
    if db.enabled and type(unit) == "string" and not (issecretvalue and issecretvalue(unit))
        and unit:find("^boss") then
      logged(event, unit)
    end
  end)
  for _, e in ipairs({ "UNIT_HEALTH", "UNIT_POWER_UPDATE", "UNIT_AURA", "UNIT_HEAL_PREDICTION",
      "UNIT_ABSORB_AMOUNT_CHANGED", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_IN_RANGE_UPDATE",
      "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_TARGET" }) do
    NF.On(e, function(event, unit) if db.enabled then onUnitEvent(event, unit) end end)
  end
  NF.On("INSPECT_READY", function(...) if db.enabled then onInspectReady(...) end end)

  -- out-of-combat snapshots: login, roster changes, target changes (throttled)
  local lastOOC = 0
  local function oocSample()
    if not db.enabled or inCombat then return end
    if GetTime() - lastOOC < 5 then return end
    lastOOC = GetTime()
    local ok, e = pcall(P.Sample)
    if not ok then NF.Error("probe sample", e) end
  end
  NF.On("GROUP_ROSTER_UPDATE", function()
    oocSample()
    if db.enabled then pcall(queueGroupInspects) end
  end)
  NF.On("PLAYER_TARGET_CHANGED", oocSample)
  C_Timer.After(3, oocSample)
  -- inspect pump: a light ticker that only does work when the queue has items
  C_Timer.NewTicker(1, function()
    if db.enabled and #inspectQueue > 0 then pcall(nextInspect) end
    if inspectPending and GetTime() - inspectPending.at > 10 then
      db.inspects[#db.inspects + 1] = { timeout = true, unit = inspectPending.unit:gsub("%d+$", "N") }
      inspectPending = nil
    end
  end)
end

function P.Command(rest)
  rest = (rest or ""):lower()
  if rest == "off" then
    db.enabled = false
    NF.Print("probe paused. /nf probe on to resume.")
  elseif rest == "on" then
    db.enabled = true
    NF.Print("probe recording.")
  elseif rest == "reset" then
    NyteFramesProbeDB = newDB()
    db = NyteFramesProbeDB
    pcall(P.Static)
    NF.Print("probe data cleared.")
  elseif rest == "now" then
    if inCombat then NF.Print("leave combat first.") return end
    P.Static()
    P.Sample()
    NF.Print("snapshot taken. /reload to save it.")
  elseif rest == "inspect" then
    if inCombat then NF.Print("leave combat first.") return end
    if not UnitExists("target") or not UnitIsPlayer("target") then
      NF.Print("target another player first.")
      return
    end
    table.insert(inspectQueue, 1, "target")
    inspectPending = nil
    lastInspect = 0
    NF.Print("inspecting your target; result is saved on /reload.")
  else
    local ctxs = 0
    for _ in pairs(db.agg) do ctxs = ctxs + 1 end
    NF.Print(string.format("probe %s. %d samples, %d fights, %d inspects, %d contexts, %d errors.",
      db.enabled and "recording" or "PAUSED", db.samples or 0, #db.fights, #db.inspects, ctxs, #db.errors))
    print("  It records by itself (out of combat and during every fight). /reload or log out to save.")
  end
end
