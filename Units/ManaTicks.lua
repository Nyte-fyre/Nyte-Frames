-- ManaTicks.lua: on the player's power bar (Phase 2 "mana cost / regen ticks")
--   * tick spark: sweeps the bar once per regen tick (2s), synced to real ticks
--   * 5-second rule: a gold spark sweeps for 5s after a cast that cost mana
--   * cast cost: while casting, shades the part of the mana bar the spell uses
--
-- Mana values are secret on this client, so ticks are found by *timing*
-- UNIT_POWER_UPDATE events, never by reading the amount: a power change that
-- isn't right after one of our casts is a regen tick candidate, and the
-- candidates that land ~2s apart set the phase. The sparks move with
-- Translation animations (no OnUpdate). Max power and spell costs are plain
-- for the player (probe); if either turns out secret the cost shade just
-- stays hidden.
local _, NF = ...
local MT = {}
NF.ManaTicks = MT

local Plain, Try = NF.Compat.Plain, NF.Compat.Try
local FLAT = "Interface\\Buttons\\WHITE8X8"

MT.TICK = 2.0          -- classic regen tick
MT.FIVE = 5.0          -- five-second rule
MT.SLACK = 0.25        -- how far off 2s a tick may land and still count
MT.CAST_WINDOW = 0.35  -- a power change this soon after our cast is the cost, not a tick
MT.Now = function() return GetTime() end

local POWER = { [0] = "mana", [3] = "energy" }
local state = { lastTick = nil, locked = false, lastCast = -100, fiveUntil = 0, kind = nil }
MT.state = state

local function cfgOf() return NF.profile.frames.player.manaTicks end
local function button() return NF.Frames and NF.Frames.byKey.player end

local function powerKind()
  local ok, pt = pcall(UnitPowerType, "player")
  return ok and POWER[Plain(pt)] or nil
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function makeSpark(layer, r, g, b)
  local s = layer:CreateTexture(nil, "OVERLAY", nil, 7)
  s:SetTexture(FLAT)
  s:SetVertexColor(r, g, b, 0.95)
  s:Hide()
  local ag = s:CreateAnimationGroup()
  local move = ag and ag:CreateAnimation("Translation")
  s.ag, s.move = ag, move
  return s
end

-- The sparks live on their own layer frame over the power bar, not inside
-- the StatusBar: on this client a bar's own textures only show over the
-- filled part, so a spark drawn in the bar stopped at the current mana.
function MT.Attach(b)
  if b.manaTick then return end
  local layer = CreateFrame("Frame", nil, b)
  layer:SetAllPoints(b.power)
  layer:SetFrameLevel(b:GetFrameLevel() + 4) -- above the bars, under the text
  pcall(layer.SetClipsChildren, layer, true)
  b.manaLayer = layer
  b.manaTick = makeSpark(layer, 1, 1, 1)
  if b.manaTick.ag then b.manaTick.ag:SetLooping("REPEAT") end
  b.fiveRule = makeSpark(layer, 1, 0.82, 0.2)
  if b.fiveRule.ag then
    b.fiveRule.ag:SetScript("OnFinished", function() b.fiveRule:Hide() MT.Refresh() end)
  end
  b.manaCost = layer:CreateTexture(nil, "OVERLAY", nil, 6)
  b.manaCost:SetTexture(FLAT)
  b.manaCost:SetVertexColor(0, 0, 0, 0.45)
  b.manaCost:Hide()
end

-- size the sparks to the bar (called from UnitButton.Layout)
function MT.Layout(b)
  if b.key ~= "player" then return end
  MT.Attach(b)
  -- full bar width from the button's own size (the bar is inset 1px each
  -- side); never the fill, which follows current mana
  local w = math.max(1, (b:GetWidth() or 2) - 2 * NF.UnitButton.BorderSize())
  local h = b.power:GetHeight()
  b.manaLayer:SetShown(b.power:IsShown())
  for _, s in ipairs({ b.manaTick, b.fiveRule }) do
    s:ClearAllPoints()
    s:SetPoint("LEFT", b.manaLayer, "LEFT", -1, 0)
    s:SetSize(2, math.max(2, h))
    if s.move then s.move:SetOffset(w, 0) end
  end
  if b.manaTick.move then b.manaTick.move:SetDuration(MT.TICK) end
  if b.fiveRule.move then b.fiveRule.move:SetDuration(MT.FIVE) end
  MT.Refresh()
end

local function play(s, offset)
  if not s.ag then return end
  s.ag:Stop()
  s:Show()
  if not (offset and offset > 0 and pcall(s.ag.Play, s.ag, false, offset)) then s.ag:Play() end
end

-- show / hide the sparks for the current state
function MT.Refresh()
  local b = button()
  if not (b and b.manaTick) then return end
  local c = cfgOf()
  local kind = powerKind()
  local now = MT.Now()
  local inFive = c.fiveSecond and kind == "mana" and now < state.fiveUntil
  local wantTick = c.ticks and kind and state.locked and not inFive
  if wantTick then
    if not (b.manaTick.ag and b.manaTick.ag:IsPlaying()) then
      play(b.manaTick, (now - state.lastTick) % MT.TICK)
    end
  else
    if b.manaTick.ag then b.manaTick.ag:Stop() end
    b.manaTick:Hide()
  end
  if not inFive then
    if b.fiveRule.ag then b.fiveRule.ag:Stop() end
    b.fiveRule:Hide()
  end
  if not (c.cost and kind == "mana") then b.manaCost:Hide() end
end

---------------------------------------------------------------------------
-- Tick detection
---------------------------------------------------------------------------
MT.intervals = {} -- [tenths of a second] = count, saved to the probe

local function noteInterval(dt)
  local k = math.floor(dt * 10 + 0.5)
  if k < 1 or k > 100 then return end
  MT.intervals[k] = (MT.intervals[k] or 0) + 1
end

function MT.OnPower(powerToken)
  local kind = powerKind()
  if not kind then return end
  local tok = Plain(powerToken)
  if type(tok) == "string" and tok:lower() ~= kind then return end
  local now = MT.Now()
  if now - state.lastCast < MT.CAST_WINDOW then return end -- the cast's cost, not a tick
  if state.lastTick then
    local dt = now - state.lastTick
    noteInterval(dt)
    local n = math.floor(dt / MT.TICK + 0.5)
    local off = math.abs(dt - n * MT.TICK)
    if n >= 1 and off <= MT.SLACK then
      state.locked = true
    elseif state.locked and dt < MT.TICK - MT.SLACK then
      return -- an extra gain between ticks (potion, proc): keep the phase
    else
      state.locked = false
    end
  end
  state.lastTick = now
  local b = button()
  if b and b.manaTick and state.locked and cfgOf().ticks then play(b.manaTick, 0) end
  MT.Refresh()
end

local function costOf(spellID)
  spellID = Plain(spellID)
  if not (spellID and C_Spell and C_Spell.GetSpellPowerCost) then return nil end
  local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
  if not ok or type(costs) ~= "table" then return nil end
  for _, c in ipairs(costs) do
    local t, n = Plain(c.type), Plain(c.cost)
    if t == 0 and type(n) == "number" then return n end
  end
  return 0
end

function MT.OnCastStart(spellID)
  local b = button()
  if not (b and b.manaCost) then return end
  local c = cfgOf()
  if not (c.cost and powerKind() == "mana") then b.manaCost:Hide() return end
  local cost = costOf(spellID)
  local max = Plain(Try(UnitPowerMax, "player", 0))
  local w = math.max(1, (b:GetWidth() or 2) - 2 * NF.UnitButton.BorderSize())
  if not (cost and cost > 0 and type(max) == "number" and max > 0 and type(w) == "number") then
    b.manaCost:Hide()
    return
  end
  -- ends at the fill's right edge and reaches back by the cost
  b.manaCost:ClearAllPoints()
  local fill = b.power:GetStatusBarTexture()
  b.manaCost:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
  b.manaCost:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
  b.manaCost:SetWidth(math.max(1, math.min(w, w * cost / max)))
  b.manaCost:Show()
end

function MT.OnCastEnd()
  local b = button()
  if b and b.manaCost then b.manaCost:Hide() end
end

function MT.OnCastSucceeded(spellID)
  state.lastCast = MT.Now()
  MT.OnCastEnd()
  if powerKind() ~= "mana" or not cfgOf().fiveSecond then return end
  local cost = costOf(spellID)
  if cost == 0 then return end -- free spell: no 5-second rule (unknown cost counts as paid)
  state.fiveUntil = state.lastCast + MT.FIVE
  local b = button()
  if b and b.fiveRule then
    play(b.fiveRule, 0)
    if b.manaTick.ag then b.manaTick.ag:Stop() end
    b.manaTick:Hide()
  end
end

---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "UNIT_POWER_UPDATE", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_DISPLAYPOWER" }) do
  pcall(ev.RegisterUnitEvent, ev, e, "player")
end
function MT.OnEvent(event, unit, a2, a3)
  if not NF.profile or not button() then return end
  local perf = NF.Perf.on
  local t0 = perf and NF.Perf.Now()
  local ok, err = pcall(function()
    if event == "UNIT_POWER_UPDATE" then MT.OnPower(a2)
    elseif event == "UNIT_SPELLCAST_START" then MT.OnCastStart(a3)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then MT.OnCastSucceeded(a3)
    elseif event == "UNIT_DISPLAYPOWER" then
      state.locked, state.lastTick = false, nil
      MT.Refresh()
    else MT.OnCastEnd() end
  end)
  if not ok then NF.Error("mana ticks " .. event, err) end
  if perf then NF.Perf.Add("mana ticks", NF.Perf.Now() - t0) end
end
ev:SetScript("OnEvent", function(_, event, unit, a2, a3) MT.OnEvent(event, unit, a2, a3) end)

-- tick intervals go to the probe so the 2s assumption can be checked
NF.On("PLAYER_LOGOUT", function()
  if type(NyteFramesProbeDB) == "table" then
    local copy = {}
    for k, v in pairs(MT.intervals) do copy[k] = v end
    NyteFramesProbeDB.manaTicks = { intervals = copy, locked = state.locked, at = time() }
  end
end)
