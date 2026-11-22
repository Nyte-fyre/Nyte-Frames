-- Overlays.lua: heal prediction, absorbs, threat border, range fade,
-- raid target / leader / assist icons. All display-safe with secret values
-- (probe #1): bars take secret values directly, range uses
-- SetAlphaFromBoolean, threat is a readable number.
local _, NF = ...
local OV = {}
NF.Overlays = OV

local Plain, Try, IsSecret = NF.Compat.Plain, NF.Compat.Try, NF.Compat.IsSecret
local FLAT = "Interface\\Buttons\\WHITE8X8"

OV.EVENTS = {
  UNIT_HEAL_PREDICTION = "UpdateBars", UNIT_ABSORB_AMOUNT_CHANGED = "UpdateBars",
  UNIT_HEAL_ABSORB_AMOUNT_CHANGED = "UpdateBars", UNIT_MAXHEALTH = "UpdateBars",
  -- no UNIT_HEALTH: the bars are anchored to the health fill's edge and move
  -- with it; their own values don't depend on current health
  UNIT_THREAT_SITUATION_UPDATE = "UpdateThreat", UNIT_IN_RANGE_UPDATE = "UpdateRange",
  INCOMING_RESURRECT_CHANGED = "UpdateStatus", INCOMING_SUMMON_CHANGED = "UpdateStatus",
}

local function cfgOf(b) return NF.profile.frames[b.key] end

function OV.Attach(b)
  -- incoming heals and absorbs extend from the end of the health fill;
  -- the health bar clips them so they never spill past the frame
  pcall(b.health.SetClipsChildren, b.health, true)
  b.healPred = CreateFrame("StatusBar", nil, b.health)
  b.healPred:SetStatusBarTexture(FLAT)
  b.healPred:SetStatusBarColor(0.35, 0.95, 0.45, 0.55)
  b.absorb = CreateFrame("StatusBar", nil, b.health)
  b.absorb:SetStatusBarTexture(FLAT)
  b.absorb:SetStatusBarColor(0.85, 0.92, 1, 0.55)
  OV.Anchor(b)

  b.raidIcon = b.textLayer:CreateTexture(nil, "OVERLAY")
  b.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
  b.raidIcon:Hide()
  b.leaderIcon = b.textLayer:CreateTexture(nil, "OVERLAY")
  b.leaderIcon:Hide()
  b.statusIcon = b.textLayer:CreateTexture(nil, "OVERLAY", nil, 7)
  b.statusIcon:Hide()
end

-- Pin the heal bar to the end of the health fill, and the absorb bar to the
-- end of the heal fill. Redone on every layout: the health texture can be
-- swapped (texture setting), and a missing fill would pin the bars past the
-- bar's right edge where the clip hides them (the v0.10 "no heal prediction").
function OV.Anchor(b)
  local fill = b.health:GetStatusBarTexture()
  local predFill = b.healPred:GetStatusBarTexture()
  b.healPred:ClearAllPoints()
  b.absorb:ClearAllPoints()
  if not (fill and predFill) then return false end
  b.healPred:SetPoint("TOPLEFT", fill, "TOPRIGHT")
  b.healPred:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT")
  b.absorb:SetPoint("TOPLEFT", predFill, "TOPRIGHT")
  b.absorb:SetPoint("BOTTOMLEFT", predFill, "BOTTOMRIGHT")
  return true
end

function OV.Layout(b, w, h)
  OV.Anchor(b)
  local barW = math.max(1, w - 2)
  b.healPred:SetWidth(barW)
  b.absorb:SetWidth(barW)
  local s = math.max(10, math.min(18, math.floor(h * 0.4)))
  b.raidIcon:SetSize(s, s)
  b.raidIcon:ClearAllPoints()
  b.raidIcon:SetPoint("CENTER", b, "TOP", 0, 0)
  b.leaderIcon:SetSize(11, 11)
  b.leaderIcon:ClearAllPoints()
  b.leaderIcon:SetPoint("CENTER", b, "TOPLEFT", 4, 0)
  local st = math.max(12, math.min(24, math.floor(h * 0.55)))
  b.statusIcon:SetSize(st, st)
  b.statusIcon:ClearAllPoints()
  b.statusIcon:SetPoint("CENTER", b, "CENTER", 0, 0)
end

function OV.UpdateBars(b)
  local o = cfgOf(b).overlays
  local u = b.unit
  local max = Try(UnitHealthMax, u)
  if o.healPrediction then
    local inc = o.healMineOnly and Try(UnitGetIncomingHeals, u, "player") or Try(UnitGetIncomingHeals, u)
    local ok = (IsSecret(inc) or inc ~= nil) and pcall(b.healPred.SetMinMaxValues, b.healPred, 0, max) and pcall(b.healPred.SetValue, b.healPred, inc)
    b.healPred:SetShown(ok and true or false)
  else
    b.healPred:Hide()
  end
  if o.absorbs then
    local abs = Try(UnitGetTotalAbsorbs, u)
    local ok = (IsSecret(abs) or abs ~= nil) and pcall(b.absorb.SetMinMaxValues, b.absorb, 0, max) and pcall(b.absorb.SetValue, b.absorb, abs)
    b.absorb:SetShown(ok and true or false)
  else
    b.absorb:Hide()
  end
end

function OV.UpdateThreat(b)
  local on = cfgOf(b).overlays.threat
  local status = on and Plain(Try(UnitThreatSituation, b.unit)) or nil
  local r, g, bl = 0, 0, 0
  if type(status) == "number" and status >= 1 and GetThreatStatusColor then
    local ok, cr, cg, cb = pcall(GetThreatStatusColor, status)
    if ok and cr then r, g, bl = cr, cg, cb end
  end
  for _, e in ipairs(b.borders) do e:SetVertexColor(r, g, bl, 1) end
end

function OV.UpdateRange(b)
  if b.key == "boss" then return end -- boss alpha belongs to the target swap (Boss.lua)
  if not cfgOf(b).overlays.rangeFade or b.key == "player" then
    b:SetAlpha(1)
    return
  end
  local a = NF.profile.general.rangeAlpha or 0.45
  local ok, inRange, checked = pcall(UnitInRange, b.unit)
  if not ok then b:SetAlpha(1) return end
  local pIn, pChecked = Plain(inRange), Plain(checked)
  if pChecked == false then b:SetAlpha(1) return end -- not a group member / not checked
  if type(pIn) == "boolean" then
    b:SetAlpha(pIn and 1 or a)
  elseif IsSecret(inRange) and b.SetAlphaFromBoolean then
    pcall(b.SetAlphaFromBoolean, b, inRange, 1, a)
  else
    b:SetAlpha(1)
  end
end

function OV.UpdateIcons(b)
  local icons = cfgOf(b).icons
  -- raid target marker
  b.raidIcon:Hide()
  if icons.raidTarget then
    local idx = Try(GetRaidTargetIndex, b.unit)
    if IsSecret(idx) or idx ~= nil then
      if SetRaidTargetIconTexture and pcall(SetRaidTargetIconTexture, b.raidIcon, idx) then b.raidIcon:Show() end
    end
  end
  -- leader / assist
  b.leaderIcon:Hide()
  if icons.leader then
    if Plain(Try(UnitIsGroupLeader, b.unit)) == true then
      b.leaderIcon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
      b.leaderIcon:Show()
    elseif Plain(Try(UnitIsGroupAssistant, b.unit)) == true then
      b.leaderIcon:SetTexture("Interface\\GroupFrame\\UI-Group-AssistantIcon")
      b.leaderIcon:Show()
    end
  end
end

---------------------------------------------------------------------------
-- Status icon (center): ready check > summon > incoming resurrect
---------------------------------------------------------------------------
local RC = "Interface\\RaidFrame\\ReadyCheck-"
OV.READY_TEX = { ready = RC .. "Ready", notready = RC .. "NotReady", waiting = RC .. "Waiting" }
OV.RES_TEX = "Interface\\RaidFrame\\Raid-Icon-Rez"
OV.SUMMON_ATLAS = { [1] = "Raid-Icon-SummonPending", [2] = "Raid-Icon-SummonAccepted", [3] = "Raid-Icon-SummonDeclined" }
OV.READY_LINGER = 6 -- seconds the results stay up after the check ends

local readyCheck = { active = false, finished = false }
OV.readyCheck = readyCheck

local function readyState(u)
  if not (readyCheck.active or readyCheck.finished) or not GetReadyCheckStatus then return nil end
  local st = Plain(Try(GetReadyCheckStatus, u))
  if st == "waiting" and readyCheck.finished then st = "notready" end -- no answer = not ready
  return OV.READY_TEX[st] and st or nil
end

local function summonState(u)
  local f = C_IncomingSummon and C_IncomingSummon.IncomingSummonStatus
  local st = f and Plain(Try(f, u))
  return OV.SUMMON_ATLAS[st] and st or nil
end

function OV.UpdateStatus(b)
  local icon = b.statusIcon
  icon:Hide()
  local on = cfgOf(b).icons.status
  if not on then return end
  local u = b.unit
  local rc = readyState(u)
  if rc then
    icon:SetTexture(OV.READY_TEX[rc])
    icon:SetTexCoord(0, 1, 0, 1)
    icon:Show()
    b.statusKind = "ready:" .. rc
    return
  end
  local sm = summonState(u)
  if sm and icon.SetAtlas and pcall(icon.SetAtlas, icon, OV.SUMMON_ATLAS[sm]) then
    icon:Show()
    b.statusKind = "summon:" .. sm
    return
  end
  if Plain(Try(UnitHasIncomingResurrection, u)) == true then
    icon:SetTexture(OV.RES_TEX)
    icon:SetTexCoord(0, 1, 0, 1)
    icon:Show()
    b.statusKind = "res"
    return
  end
  b.statusKind = nil
end

function OV.UpdateAll(b)
  OV.UpdateBars(b)
  OV.UpdateThreat(b)
  OV.UpdateRange(b)
  OV.UpdateIcons(b)
  OV.UpdateStatus(b)
end

-- group-wide events
local function each(fn)
  for _, b in ipairs(NF.UnitButton.all) do
    if b:IsShown() then
      local ok, err = pcall(fn, b)
      if not ok then NF.Error("overlay", err) end
    end
  end
end
NF.On("RAID_TARGET_UPDATE", function() each(OV.UpdateIcons) end)
NF.On("PARTY_LEADER_CHANGED", function() each(OV.UpdateIcons) end)
NF.On("GROUP_ROSTER_UPDATE", function() each(OV.UpdateIcons) end)

-- ready check: everyone's icon at once
local linger = 0
NF.On("READY_CHECK", function()
  readyCheck.active, readyCheck.finished = true, false
  linger = linger + 1
  each(OV.UpdateStatus)
end)
NF.On("READY_CHECK_CONFIRM", function() each(OV.UpdateStatus) end)
NF.On("READY_CHECK_FINISHED", function()
  readyCheck.active, readyCheck.finished = false, true
  each(OV.UpdateStatus)
  linger = linger + 1
  local mine = linger
  C_Timer.After(OV.READY_LINGER, function()
    if mine ~= linger then return end -- a new check started meanwhile
    readyCheck.finished = false
    each(OV.UpdateStatus)
  end)
end)
