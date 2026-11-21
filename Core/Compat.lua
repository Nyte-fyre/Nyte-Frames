-- Compat.lua: feature probes and safe wrappers. Nothing here branches on the
-- interface number; every decision comes from what actually exists.
--
-- Known from earlier addons on this client (see docs/api-probe.md):
--   * Interface 16001, a retail ("Midnight"-style) engine with Classic content.
--   * Secret values are active: UnitHealth/UnitPower("player") are secret even
--     out of combat. Secret values can be handed to StatusBar:SetValue and
--     FontString:SetText/SetFormattedText, but never compared or used in math.
local _, NF = ...
local Compat = {}
NF.Compat = Compat

local _G = _G
local issecretvalue = _G.issecretvalue

-- true when v is a secret value (always false on clients without secrets)
function Compat.IsSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) == true
end

-- v if it's a normal, usable value; otherwise nil
function Compat.Plain(v)
  if v == nil or Compat.IsSecret(v) then return nil end
  return v
end

-- pcall that returns only the first result, or nil on error
function Compat.Try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

-- Resolve "C_Foo.Bar" or "Bar" to a function (or nil)
function Compat.Get(path)
  local obj = _G
  for part in path:gmatch("[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
  end
  return obj
end

-- Every API the frames might use. Compat.has[name] = true/false after Run().
Compat.APIS = {
  -- roles / spec
  "UnitGroupRolesAssigned", "GetRaidRosterInfo", "NotifyInspect", "ClearInspectPlayer",
  "CanInspect", "GetInspectSpecialization", "C_ClassTalents.GetActiveConfigID",
  "C_Traits.GetConfigInfo", "C_Traits.GetTreeNodes", "C_Traits.GetNodeInfo",
  "C_SpecializationInfo.GetSpecialization", "GetSpecialization",
  -- timers / spells / power
  "C_Timer.After", "C_Timer.NewTicker", "C_Spell.GetSpellInfo", "C_Spell.IsSpellInRange",
  "IsSpellInRange", "C_Spell.GetSpellName",
  -- health / power, incl. secret-safe display helpers
  "UnitHealth", "UnitHealthMax", "UnitHealthPercent", "UnitHealthMissing",
  "UnitPower", "UnitPowerMax", "UnitPowerPercent", "UnitPowerType",
  "UnitGetIncomingHeals", "UnitGetTotalAbsorbs", "UnitGetTotalHealAbsorbs",
  "UnitGetDetailedHealPrediction", "CreateUnitHealPredictionCalculator",
  "AbbreviateNumbers", "AbbreviateLargeNumbers", "BreakUpLargeNumbers",
  "C_StringUtil.TruncateWhenZero", "C_CurveUtil.CreateCurve", "C_CurveUtil.CreateColorCurve",
  "C_CurveUtil.EvaluateColorFromBoolean",
  -- state
  "UnitThreatSituation", "UnitDetailedThreatSituation", "GetThreatStatusColor",
  "UnitInRange", "UnitIsConnected", "UnitIsDeadOrGhost", "UnitIsGhost", "UnitIsAFK",
  "UnitReaction", "UnitIsPlayer", "UnitCanAttack", "UnitIsUnit", "UnitPhaseReason",
  "UnitIsGroupLeader", "UnitIsGroupAssistant", "GetRaidTargetIndex", "SetRaidTargetIconTexture",
  "UnitHasIncomingResurrection", "C_ClassColor.GetClassColor",
  -- casts
  "UnitCastingInfo", "UnitChannelInfo", "UnitCastingDuration", "UnitChannelDuration",
  -- auras
  "C_UnitAuras.GetAuraDataByIndex", "C_UnitAuras.GetUnitAuras", "C_UnitAuras.GetUnitAuraInstanceIDs",
  "C_UnitAuras.GetAuraDataByAuraInstanceID", "C_UnitAuras.GetAuraDuration",
  "C_UnitAuras.GetAuraApplicationDisplayCount", "C_UnitAuras.GetAuraDispelTypeColor",
  "C_UnitAuras.IsAuraFilteredOutByInstanceID", "AuraUtil.ForEachAura",
  -- secrets / restrictions
  "issecretvalue", "issecrettable", "canaccessvalue", "C_Secrets.ShouldUnitHealthMaxBeSecret",
  "C_Secrets.ShouldAurasBeSecret", "C_Secrets.ShouldUnitPowerBeSecret",
  "C_RestrictedActions.IsAddOnRestrictionActive",
  -- encounters / bosses
  "CombatLogGetCurrentEventInfo", "C_EncounterJournal", "IsEncounterInProgress",
  -- secure frames
  "RegisterUnitWatch", "UnregisterUnitWatch", "RegisterStateDriver", "SecureHandlerWrapScript",
  "InCombatLockdown", "C_Settings", "Settings.RegisterCanvasLayoutCategory",
  -- tooltips / menus
  "UnitPopup_OpenMenu", "MenuUtil.CreateContextMenu", "ToggleDropDownMenu",
}

Compat.has = {}

function Compat.Run()
  for _, name in ipairs(Compat.APIS) do
    Compat.has[name] = Compat.Get(name) ~= nil
  end
  Compat.ran = true
end

-- Shims used by later milestones. Each one degrades instead of erroring.
function Compat.After(seconds, fn)
  if C_Timer and C_Timer.After then return C_Timer.After(seconds, fn) end
  local f, t = CreateFrame("Frame"), 0
  f:SetScript("OnUpdate", function(self, e)
    t = t + e
    if t >= seconds then self:SetScript("OnUpdate", nil) fn() end
  end)
end

function Compat.Role(unit)
  if not UnitGroupRolesAssigned then return nil end
  local r = Compat.Try(UnitGroupRolesAssigned, unit)
  r = Compat.Plain(r)
  if r == "TANK" or r == "HEALER" or r == "DAMAGER" then return r end
  return nil
end

function Compat.ClassColor(classFile)
  local c = classFile and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classFile]
  if c then return c.r, c.g, c.b end
  return 0.5, 0.5, 0.5
end
