-- UnitButton.lua: one flat secure unit frame (health on top, power below).
--
-- Secret-value rules (docs/api-probe.md): health/power values may be secret,
-- so they go straight into StatusBar:SetValue and FontString:SetFormattedText
-- and are never compared, added or concatenated in Lua. Every display path
-- has a pcall'd fallback chain so a refused value hides text, never errors.
local _, NF = ...
local UB = {}
NF.UnitButton = UB

local Compat = NF.Compat
local Plain, Try = Compat.Plain, Compat.Try

UB.REACTION = {
  hostile = { 0.85, 0.20, 0.20 },
  neutral = { 0.95, 0.82, 0.25 },
  friendly = { 0.30, 0.78, 0.30 },
  unknown = { 0.45, 0.55, 0.45 },
}
UB.POWER = {
  MANA = { 0.00, 0.45, 0.95 }, RAGE = { 0.85, 0.15, 0.15 }, ENERGY = { 1.00, 0.85, 0.15 },
  FOCUS = { 1.00, 0.50, 0.25 }, RUNIC_POWER = { 0.00, 0.82, 1.00 },
  [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY", [6] = "RUNIC_POWER",
}
UB.DEAD = { 0.35, 0.35, 0.35 }

---------------------------------------------------------------------------
-- Settings helpers
---------------------------------------------------------------------------
local function cfgOf(b) return NF.profile.frames[b.key] end
local function general() return NF.profile.general end

-- "both" for the player frame, otherwise the per-frame override or global
function UB.TextMode(b)
  if b.key == "player" then return "both" end
  return cfgOf(b).textMode or general().textMode
end

---------------------------------------------------------------------------
-- Display-safe value helpers
---------------------------------------------------------------------------
local function setFmt(fs, fmt, ...)
  return (pcall(fs.SetFormattedText, fs, fmt, ...))
end

-- Health/power as display text (maybe secret). nil when nothing usable.
local function numberText(v)
  if v == nil then return nil end
  if general().abbreviate then
    local ok, s = pcall(AbbreviateNumbers, v)
    if ok and s ~= nil then return s end
  else
    local ok, s = pcall(BreakUpLargeNumbers, v)
    if ok and s ~= nil then return s end
  end
  return v -- raw number (possibly secret); "%s" formats it
end

-- 0-100 percent (maybe secret), or nil
local function percent(fnPct, cur, max, ...)
  local curve = CurveConstants and CurveConstants.ScaleTo100
  if fnPct and curve then
    local ok, v = pcall(fnPct, ...)
    if ok and v ~= nil then return v end
  end
  local c, m = Plain(cur), Plain(max)
  if type(c) == "number" and type(m) == "number" and m > 0 then return c / m * 100 end
  return nil
end

local function healthPercent(u, cur, max)
  return percent(UnitHealthPercent, cur, max, u, true, CurveConstants and CurveConstants.ScaleTo100)
end

local function powerPercent(u, ptype, cur, max)
  return percent(UnitPowerPercent, cur, max, u, ptype, false, CurveConstants and CurveConstants.ScaleTo100)
end

-- Writes value text by mode; returns true if something was shown.
local function writeValue(fs, mode, cur, max, pct)
  local num = numberText(cur)
  if mode == "both" then
    if num ~= nil and pct ~= nil and setFmt(fs, "%s | %.0f%%", num, pct) then return true end
    if num ~= nil and setFmt(fs, "%s", num) then return true end
    if pct ~= nil and setFmt(fs, "%.0f%%", pct) then return true end
  elseif mode == "number" then
    if num ~= nil and setFmt(fs, "%s", num) then return true end
    if pct ~= nil and setFmt(fs, "%.0f%%", pct) then return true end
  else
    if pct ~= nil and setFmt(fs, "%.0f%%", pct) then return true end
    if num ~= nil and setFmt(fs, "%s", num) then return true end
  end
  fs:SetText("")
  return false
end

local function setBar(bar, cur, max, pctFallback)
  local ok = pcall(bar.SetMinMaxValues, bar, 0, max) and pcall(bar.SetValue, bar, cur)
  if ok then return true end
  if pctFallback ~= nil then
    ok = pcall(bar.SetMinMaxValues, bar, 0, 100) and pcall(bar.SetValue, bar, pctFallback)
    if ok then return true end
  end
  pcall(bar.SetMinMaxValues, bar, 0, 1)
  pcall(bar.SetValue, bar, 1)
  return false
end

---------------------------------------------------------------------------
-- Creation
---------------------------------------------------------------------------
local function edge(parent, layer)
  local t = parent:CreateTexture(nil, layer or "BORDER")
  t:SetTexture(NF.Media.FLAT)
  return t
end

UB.UNIT_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
  "UNIT_DISPLAYPOWER", "UNIT_NAME_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS", "UNIT_FACTION",
  "UNIT_HEAL_PREDICTION", "UNIT_ABSORB_AMOUNT_CHANGED", "UNIT_HEAL_ABSORB_AMOUNT_CHANGED",
  "UNIT_THREAT_SITUATION_UPDATE", "UNIT_IN_RANGE_UPDATE",
  "INCOMING_RESURRECT_CHANGED", "INCOMING_SUMMON_CHANGED",
  "UNIT_LEVEL", "UNIT_CLASSIFICATION_CHANGED" }
UB.all = {}

-- key = settings key ("party"); globalName defaults to NyteFrames_<key>
function UB.Create(key, unit, globalName)
  local b = CreateFrame("Button", globalName or ("NyteFrames_" .. key), UIParent, "SecureUnitButtonTemplate")
  b.key, b.unit = key, unit
  b.compact = (key == "party" or key == "raid")
  b.oocKey = "size:" .. (globalName or key) -- unique per button for the combat queue
  b:SetAttribute("unit", unit)
  b:SetAttribute("*type1", "target")
  b:SetAttribute("*type2", "togglemenu")
  b:RegisterForClicks("AnyUp")
  b:SetFrameStrata("LOW")
  b:SetClampedToScreen(true)

  b.bg = edge(b, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetVertexColor(0.06, 0.06, 0.07, 0.9)
  -- black border (thickness set in Layout: general.borderSize)
  b.borders = {}
  for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = edge(b, "OVERLAY")
    t:SetVertexColor(0, 0, 0, 1)
    t:SetPoint(pts[1])
    t:SetPoint(pts[2])
    b.borders[i] = t
  end

  b.health = CreateFrame("StatusBar", nil, b)
  -- a fill texture must exist before Overlays anchors to it (a StatusBar has
  -- none until SetStatusBarTexture; anchoring to nil pins to the bar's edge)
  b.health:SetStatusBarTexture(NF.Media.FLAT)
  b.health.bg = edge(b.health, "BACKGROUND")
  b.health.bg:SetAllPoints()
  b.power = CreateFrame("StatusBar", nil, b)
  b.power.bg = edge(b.power, "BACKGROUND")
  b.power.bg:SetAllPoints()

  -- text sits above both bars
  b.textLayer = CreateFrame("Frame", nil, b)
  b.textLayer:SetAllPoints()
  b.textLayer:SetFrameLevel(b:GetFrameLevel() + 5)
  b.nameText = b.textLayer:CreateFontString(nil, "OVERLAY")
  b.healthText = b.textLayer:CreateFontString(nil, "OVERLAY")
  b.powerText = b.textLayer:CreateFontString(nil, "OVERLAY")
  b.levelText = b.textLayer:CreateFontString(nil, "OVERLAY")
  b.levelText:Hide()
  for _, fs in ipairs({ b.nameText, b.healthText, b.powerText, b.levelText }) do
    fs:SetWordWrap(false)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
  end
  b.nameText:SetJustifyH("LEFT")
  b.levelText:SetJustifyH("LEFT")
  b.healthText:SetJustifyH("RIGHT")
  b.powerText:SetJustifyH("RIGHT")

  b:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    pcall(GameTooltip_SetDefaultAnchor, GameTooltip, self)
    if pcall(GameTooltip.SetUnit, GameTooltip, self.unit) then GameTooltip:Show() end
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  b:SetScript("OnShow", function(self) UB.UpdateAll(self) end)
  b:SetScript("OnEvent", UB.OnEvent)

  for _, e in ipairs(UB.UNIT_EVENTS) do
    pcall(b.RegisterUnitEvent, b, e, unit)
  end

  -- role icon (party/raid): atlas if the client has it, else a letter
  b.roleIcon = b.textLayer:CreateTexture(nil, "OVERLAY")
  b.roleIcon:SetSize(12, 12)
  b.roleIcon:Hide()
  b.roleText = b.textLayer:CreateFontString(nil, "OVERLAY")
  b.roleText:SetShadowOffset(1, -1)
  b.roleText:Hide()

  NF.Overlays.Attach(b)
  UB.all[#UB.all + 1] = b

  -- Clique-style click casting
  ClickCastFrames = ClickCastFrames or {}
  ClickCastFrames[b] = true

  UB.Layout(b)
  return b
end

---------------------------------------------------------------------------
-- Layout (size, split, fonts, texture). Secure parts only out of combat.
---------------------------------------------------------------------------

-- Point a pooled button at another unit (party/raid). Out of combat only.
function UB.SetUnit(b, unit)
  if b.unit == unit then return end
  b:SetAttribute("unit", unit)
  b.unit = unit
  for _, e in ipairs(UB.UNIT_EVENTS) do
    pcall(b.UnregisterEvent, b, e)
    pcall(b.RegisterUnitEvent, b, e, unit)
  end
end

local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local ROLE_LETTER = { TANK = "|cff6fa8ffT|r", HEALER = "|cff6fff8fH|r", DAMAGER = "|cffff7070D|r" }
UB.ROLE_LETTER = ROLE_LETTER

function UB.SetRole(b, role)
  b.role = role
  local cfg = cfgOf(b)
  local show = role and cfg.icons and cfg.icons.role
  b.roleIcon:Hide()
  b.roleText:Hide()
  if not show then return end
  if ROLE_ATLAS[role] and pcall(b.roleIcon.SetAtlas, b.roleIcon, ROLE_ATLAS[role]) and b.roleIcon:GetAtlas() then
    b.roleIcon:Show()
  else
    b.roleText:SetText(ROLE_LETTER[role] or "")
    b.roleText:Show()
  end
end
-- border thickness in UI units (bars sit inside it)
function UB.BorderSize()
  local n = tonumber(general().borderSize) or 2
  return math.max(1, math.min(4, math.floor(n)))
end

-- Fixed name colors (class / reaction are worked out per unit)
UB.NAME_COLORS = { white = { 1, 1, 1 }, black = { 0, 0, 0 }, gold = { 1, 0.82, 0 }, gray = { 0.75, 0.75, 0.75 } }

function UB.Layout(b)
  local cfg, g = cfgOf(b), general()
  local w, h = cfg.width, cfg.height
  local pct = math.max(0, math.min(60, cfg.powerHeightPct or 0))
  local tex = NF.Media.Texture(g.texture)
  local font = NF.Media.Font(g.font)

  NF.RunOOC(b.oocKey, function()
    b:SetSize(w, h)
    UB.Place(b)
  end)

  local bs = UB.BorderSize()
  for i, t in ipairs(b.borders) do
    if i <= 2 then t:SetHeight(bs) else t:SetWidth(bs) end
  end
  local inner = h - 2 * bs
  local powerH = (pct > 0) and math.max(1, math.floor(inner * pct / 100 + 0.5)) or 0
  local gap = powerH > 0 and 1 or 0
  b.health:ClearAllPoints()
  b.health:SetPoint("TOPLEFT", bs, -bs)
  b.health:SetPoint("TOPRIGHT", -bs, -bs)
  b.health:SetHeight(math.max(1, inner - powerH - gap))
  b.power:ClearAllPoints()
  b.power:SetPoint("BOTTOMLEFT", bs, bs)
  b.power:SetPoint("BOTTOMRIGHT", -bs, bs)
  b.power:SetHeight(math.max(1, powerH))
  b.power:SetShown(powerH > 0)

  for _, bar in ipairs({ b.health, b.power }) do
    bar:SetStatusBarTexture(tex)
    bar.bg:SetTexture(tex)
  end

  local size = g.fontSize or 11
  if h >= 50 then size = size + 1 end
  b.nameText:SetFont(font, size, "")
  b.healthText:SetFont(font, size, "")
  b.powerText:SetFont(font, math.max(8, size - 2), "")
  b.levelText:SetFont(font, size, "")

  NF.Overlays.Layout(b, w, h)
  if b.key == "player" and NF.ManaTicks then NF.ManaTicks.Layout(b) end
  b.roleIcon:ClearAllPoints()
  b.roleIcon:SetPoint("TOPRIGHT", b.health, "TOPRIGHT", -2, -2)
  b.roleText:SetFont(font, math.max(8, size - 2), "")
  b.roleText:ClearAllPoints()
  b.roleText:SetPoint("TOPRIGHT", b.health, "TOPRIGHT", -3, -2)

  if b.compact then
    -- small group frames: name on top, value text under it
    b.nameText:ClearAllPoints()
    b.nameText:SetPoint("TOPLEFT", b.health, "TOPLEFT", 3, -3)
    b.nameText:SetWidth(math.max(10, w - 20))
    b.healthText:ClearAllPoints()
    b.healthText:SetPoint("BOTTOMRIGHT", b.health, "BOTTOMRIGHT", -3, 3)
    b.healthText:SetWidth(math.max(10, w - 8))
    b.nameText:SetShown(cfg.showName)
    b.healthText:SetShown(cfg.showHealthText)
    b.powerText:Hide()
    b.levelText:Hide()
    UB.SetRole(b, b.role)
    UB.UpdateAll(b)
    return
  end

  -- name gets the space the value text doesn't need
  local reserve = (b.key == "player") and math.floor(w * 0.45) or math.floor(w * 0.32)
  b.healthText:ClearAllPoints()
  b.healthText:SetPoint("RIGHT", b.health, "RIGHT", -4, 0)
  b.healthText:SetWidth(reserve)
  b.levelText:ClearAllPoints()
  b.levelText:SetPoint("LEFT", b.health, "LEFT", 4, 0)
  b.nameMaxW = math.max(10, w - reserve - 12)
  b.nameText:SetShown(cfg.showName)
  b.healthText:SetShown(cfg.showHealthText)
  b.powerText:ClearAllPoints()
  b.powerText:SetPoint("RIGHT", b.power, "RIGHT", -4, 0)
  b.powerText:SetWidth(w - 8)
  b.powerText:SetShown(cfg.showPowerText and powerH >= 8)

  UB.UpdateAll(b)
end

-- Position: saved pos, else the reference layout scaled to this screen.
function UB.Place(b)
  if b.placeFn then return b.placeFn(b) end
  local cfg = cfgOf(b)
  b:ClearAllPoints()
  local p = cfg.pos
  if p and p.point then
    b:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
  else
    local r = cfg.refPos or { x = 0, y = 0 }
    b:SetPoint("CENTER", UIParent, "CENTER", r.x, r.y)
  end
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------
local function unitState(u)
  local connected = Plain(Try(UnitIsConnected, u))
  if connected == false then return NF.L["Offline"] end
  local ghost = Plain(Try(UnitIsGhost, u))
  if ghost == true then return NF.L["Ghost"] end
  local dead = Plain(Try(UnitIsDeadOrGhost, u))
  if dead == true then return NF.L["Dead"] end
  return nil
end

function UB.UpdateColors(b)
  local u, cfg = b.unit, cfgOf(b)
  local r, g, bl
  local state = unitState(u)
  local okC, _, class = pcall(UnitClass, u)
  class = okC and Plain(class) or nil
  local isPlayer = Plain(Try(UnitIsPlayer, u))
  local reactionKey = "unknown"
  local reaction = Plain(Try(UnitReaction, u, "player"))
  if type(reaction) == "number" then
    reactionKey = reaction <= 3 and "hostile" or (reaction == 4 and "neutral" or "friendly")
  else
    local canAttack = Plain(Try(UnitCanAttack, "player", u))
    if canAttack == true then reactionKey = "hostile" elseif canAttack == false then reactionKey = "friendly" end
  end
  local rc = UB.REACTION[reactionKey]

  if state then
    r, g, bl = unpack(UB.DEAD)
  elseif isPlayer and class then
    r, g, bl = Compat.ClassColor(class)
  else
    r, g, bl = rc[1], rc[2], rc[3]
  end
  b.health:SetStatusBarColor(r, g, bl)
  b.health.bg:SetVertexColor(r * 0.25, g * 0.25, bl * 0.25, 1)

  local mode = cfg.nameColor
  if mode == "class" and class then
    b.nameText:SetTextColor(Compat.ClassColor(class))
  elseif mode == "reaction" then
    b.nameText:SetTextColor(rc[1], rc[2], rc[3])
  else
    local c = UB.NAME_COLORS[mode] or UB.NAME_COLORS.white
    b.nameText:SetTextColor(c[1], c[2], c[3])
  end
  -- a dark name needs a light shadow to stay readable on dark bars
  if mode == "black" then
    b.nameText:SetShadowColor(1, 1, 1, 0.35)
  else
    b.nameText:SetShadowColor(0, 0, 0, 1)
  end
end

function UB.UpdateName(b)
  local u = b.unit
  local n = Try(GetUnitName, u, true)
  if n == nil then n = Try(UnitName, u) end
  local plain = Plain(n)
  if type(plain) == "string" then n = plain:gsub("%-.*$", "") end
  if n == nil or not pcall(b.nameText.SetText, b.nameText, n) then b.nameText:SetText("") end
end

function UB.UpdateHealth(b)
  local u = b.unit
  local cur, max = Try(UnitHealth, u), Try(UnitHealthMax, u)
  local pct = healthPercent(u, cur, max)
  setBar(b.health, cur, max, pct)
  local state = unitState(u)
  if state then
    b.healthText:SetText(state)
  elseif cfgOf(b).showHealthText then
    writeValue(b.healthText, UB.TextMode(b), cur, max, pct)
  end
  if state ~= b.lastState then
    b.lastState = state
    UB.UpdateColors(b)
  end
end

function UB.UpdatePower(b)
  local u = b.unit
  if not b.power:IsShown() then return end
  local okT, ptype, token = pcall(UnitPowerType, u)
  ptype, token = okT and Plain(ptype) or nil, okT and Plain(token) or nil
  local c = (token and PowerBarColor and PowerBarColor[token])
  local r, g, bl
  if c and c.r then
    r, g, bl = c.r, c.g, c.b
  else
    local key = token or (ptype and UB.POWER[ptype]) or "MANA"
    local col = UB.POWER[key] or UB.POWER.MANA
    r, g, bl = col[1], col[2], col[3]
  end
  b.power:SetStatusBarColor(r, g, bl)
  b.power.bg:SetVertexColor(r * 0.25, g * 0.25, bl * 0.25, 1)
  local cur, max = Try(UnitPower, u), Try(UnitPowerMax, u)
  local pct = powerPercent(u, ptype, cur, max)
  setBar(b.power, cur, max, pct)
  if b.powerText:IsShown() then
    local mode = (b.key == "player") and "both" or UB.TextMode(b)
    writeValue(b.powerText, mode, cur, max, pct)
  end
end

-- Level + classification, e.g. "62 Elite", "60 Rare", "?? Boss". Returns the
-- display string (with color codes) or nil. Level -1 is a skull (too high to
-- see). The level is colored by difficulty against the player's level.
UB.CLASSIFICATION_COLOR = { elite = "ffd100", rare = "c7c7d9", rareelite = "c7c7d9", worldboss = "ff4040" }
-- normal / trivial / minus get no tag
function UB.ClassificationLabel(class)
  local L = NF.L
  if class == "elite" then return L["Elite"] end
  if class == "rare" then return L["Rare"] end
  if class == "rareelite" then return L["Rare Elite"] end
  if class == "worldboss" then return L["Boss"] end
  return nil
end
local function hex(c)
  if type(c) ~= "table" or type(c.r) ~= "number" then return nil end
  return string.format("%02x%02x%02x", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
end

function UB.LevelText(u)
  local level = Plain(Try(UnitLevel, u))
  local class = Plain(Try(UnitClassification, u))
  if type(level) ~= "number" then return nil end
  local lvl, col
  if level < 0 then
    lvl, col = "??", "ff4040"
  else
    lvl = tostring(level)
    local okD, c = pcall(GetCreatureDifficultyColor, level)
    if not okD or type(c) ~= "table" then okD, c = pcall(GetQuestDifficultyColor, level) end
    col = (okD and hex(c)) or "ffd100"
  end
  local s = "|cff" .. col .. lvl .. "|r"
  local tag = type(class) == "string" and UB.ClassificationLabel(class)
  if tag then s = s .. " |cff" .. UB.CLASSIFICATION_COLOR[class] .. tag .. "|r" end
  return s
end

-- Shows the level text left of the name (player/target, when enabled) and
-- gives the name whatever width is left.
function UB.UpdateLevel(b)
  if b.compact then return end
  local text = cfgOf(b).showLevel and UB.LevelText(b.unit) or nil
  local lw = 0
  if text then
    b.levelText:SetText(text)
    b.levelText:Show()
    local okW, sw = pcall(b.levelText.GetStringWidth, b.levelText)
    lw = (okW and type(sw) == "number") and math.ceil(sw) + 4 or 0
  else
    b.levelText:SetText("")
    b.levelText:Hide()
  end
  b.levelWidth = lw
  b.nameText:ClearAllPoints()
  b.nameText:SetPoint("LEFT", b.health, "LEFT", 4 + lw, 0)
  b.nameText:SetWidth(math.max(10, (b.nameMaxW or 80) - lw))
end

function UB.UpdateAll(b)
  if not b:IsShown() and b.unit ~= "player" then return end
  local exists = Plain(Try(UnitExists, b.unit))
  if exists == false then return end
  b.lastState = unitState(b.unit)
  UB.UpdateColors(b)
  UB.UpdateName(b)
  UB.UpdateLevel(b)
  UB.UpdateHealth(b)
  UB.UpdatePower(b)
  NF.Overlays.UpdateAll(b)
end

-- UNIT_FLAGS fires for every unit entering/leaving combat, so in a raid it's
-- one of the busiest events. Only a dead/ghost/offline change needs a redraw.
function UB.UpdateFlags(b)
  local state = unitState(b.unit)
  if state ~= b.lastState then UB.UpdateAll(b) end
end

local HANDLERS = {
  UNIT_HEALTH = UB.UpdateHealth, UNIT_MAXHEALTH = UB.UpdateHealth,
  UNIT_POWER_UPDATE = UB.UpdatePower, UNIT_MAXPOWER = UB.UpdatePower,
  UNIT_DISPLAYPOWER = UB.UpdatePower, UNIT_NAME_UPDATE = UB.UpdateName,
  UNIT_LEVEL = UB.UpdateLevel, UNIT_CLASSIFICATION_CHANGED = UB.UpdateLevel,
  UNIT_CONNECTION = UB.UpdateAll, UNIT_FLAGS = UB.UpdateFlags, UNIT_FACTION = UB.UpdateColors,
}

function UB.OnEvent(b, event)
  -- hidden buttons (empty raid slots, party frames while in a raid) do no
  -- work; OnShow runs a full update when they appear
  if b.unit ~= "player" and not b:IsShown() then return end
  local perf = NF.Perf.on
  local t0 = perf and NF.Perf.Now()
  UB.Dispatch(b, event)
  if perf then NF.Perf.Add(event .. " (" .. b.key .. ")", NF.Perf.Now() - t0) end
end

function UB.Dispatch(b, event)
  local fn = HANDLERS[event]
  if fn then
    local ok, err = pcall(fn, b)
    if not ok then NF.Error(b.key .. " " .. event, err) end
  end
  local ov = NF.Overlays.EVENTS[event]
  if ov then
    local ok, err = pcall(NF.Overlays[ov], b)
    if not ok then NF.Error(b.key .. " " .. event, err) end
  end
end
