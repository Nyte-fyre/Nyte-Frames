-- CastBar.lua: cast bars under the player and target frames (boss later).
-- Cast info is secret for other units (party probe), so the bar runs off the
-- duration object (UnitCastingDuration / UnitChannelDuration ->
-- StatusBar:SetTimerDuration), the spell name goes straight to SetText, and
-- "not interruptible" colors the bar via SetVertexColorFromBoolean.
local _, NF = ...
local CB = {}
NF.CastBar = CB

local Plain, Try, IsSecret = NF.Compat.Plain, NF.Compat.Try, NF.Compat.IsSecret
local FLAT = "Interface\\Buttons\\WHITE8X8"
local HEIGHT = 14

CB.COLOR_CAST = { 1.0, 0.78, 0.25 }
CB.COLOR_CHANNEL = { 0.45, 0.75, 1.0 }
CB.COLOR_LOCKED = { 0.6, 0.6, 0.6 } -- not interruptible

local EVENTS = {
  "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START",
  "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP",
  "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local function present(v) return IsSecret(v) or v ~= nil end

local function color(bar, notInt, base)
  local tex = bar:GetStatusBarTexture()
  if type(Plain(notInt)) == "boolean" then
    local c = Plain(notInt) and CB.COLOR_LOCKED or base
    tex:SetVertexColor(c[1], c[2], c[3], 1)
  elseif IsSecret(notInt) and tex.SetVertexColorFromBoolean and CreateColor then
    local ok = pcall(tex.SetVertexColorFromBoolean, tex, notInt,
      CreateColor(CB.COLOR_LOCKED[1], CB.COLOR_LOCKED[2], CB.COLOR_LOCKED[3], 1),
      CreateColor(base[1], base[2], base[3], 1))
    if not ok then tex:SetVertexColor(base[1], base[2], base[3], 1) end
  else
    tex:SetVertexColor(base[1], base[2], base[3], 1)
  end
end

local function runTimer(bar, duration, channel)
  if not duration then return false end
  local dir = Enum and Enum.StatusBarTimerDirection
  local interp = Enum and Enum.StatusBarInterpolation
  if channel and dir and interp then
    if pcall(bar.SetTimerDuration, bar, duration, interp.Immediate, dir.RemainingTime) then return true end
  end
  return pcall(bar.SetTimerDuration, bar, duration)
end

-- Player cast bar: a red zone as long as your latency at the end the cast
-- finishes (right for casts, left for channels, which drain). Once the cast
-- is inside it you can queue the next one. Player cast times are plain
-- numbers (probe); for anyone else this stays hidden.
function CB.LatencyMS()
  if not GetNetStats then return nil end
  local ok, _, _, home, world = pcall(GetNetStats)
  if not ok then return nil end
  home, world = Plain(home), Plain(world)
  local ms = type(world) == "number" and world or home
  if type(ms) ~= "number" or ms <= 0 then return nil end
  return ms
end

function CB.UpdateLatency(bar, startMS, endMS, channel)
  local z = bar.latency
  if not z then return end
  z:Hide()
  if bar.unit ~= "player" or not NF.profile.frames.player.castLatency then return end
  startMS, endMS = Plain(startMS), Plain(endMS)
  local lag = CB.LatencyMS()
  if type(startMS) ~= "number" or type(endMS) ~= "number" or not lag then return end
  local dur = endMS - startMS
  if dur <= 0 then return end
  local w = bar.barWidth or 0
  local zw = math.max(1, math.min(w, w * lag / dur))
  z:ClearAllPoints()
  local side = channel and "LEFT" or "RIGHT"
  z:SetPoint("TOP" .. side, bar.latencyLayer, "TOP" .. side)
  z:SetPoint("BOTTOM" .. side, bar.latencyLayer, "BOTTOM" .. side)
  z:SetWidth(zw)
  z:Show()
  bar.latencyWidth = zw
end

function CB.Start(bar)
  local u = bar.unit
  local channel = false
  local okC, name, _, texture, startMS, endMS, _, _, notInt = pcall(UnitCastingInfo, u)
  if not (okC and present(name)) then
    local okH, cname, _, ctex, cstart, cend, _, cnotInt = pcall(UnitChannelInfo, u)
    if not (okH and present(cname)) then bar:Hide() return end
    name, texture, notInt, channel = cname, ctex, cnotInt, true
    startMS, endMS = cstart, cend
  end
  local duration = channel and Try(UnitChannelDuration, u) or Try(UnitCastingDuration, u)
  if not runTimer(bar, duration, channel) then bar:Hide() return end
  bar.duration = duration
  if not pcall(bar.text.SetText, bar.text, name) then bar.text:SetText("") end
  if not pcall(bar.icon.SetTexture, bar.icon, texture) then bar.icon:SetTexture(nil) end
  color(bar, notInt, channel and CB.COLOR_CHANNEL or CB.COLOR_CAST)
  CB.UpdateLatency(bar, startMS, endMS, channel)
  bar.elapsed = 1
  bar:Show()
end

local function onUpdate(bar, e)
  bar.elapsed = (bar.elapsed or 0) + e
  if bar.elapsed < 0.1 then return end
  bar.elapsed = 0
  local d = bar.duration
  if d and d.GetRemainingDuration then
    local ok, rem = pcall(d.GetRemainingDuration, d)
    if not (ok and pcall(bar.time.SetFormattedText, bar.time, "%.1f", rem)) then bar.time:SetText("") end
  end
end

-- Every cast event just re-reads the unit's current cast: a STOP/FAILED can
-- arrive after the next cast already started, so "hide on stop" would be wrong.
local function onEvent(bar)
  CB.Start(bar)
end

function CB.Create(b)
  local bar = CreateFrame("StatusBar", nil, b)
  bar.unit = b.unit
  bar:SetStatusBarTexture(FLAT)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(FLAT)
  bg:SetPoint("TOPLEFT", -1, 1)
  bg:SetPoint("BOTTOMRIGHT", 1, -1)
  bg:SetVertexColor(0, 0, 0, 0.85)
  -- the icon sits in its own small frame so Masque can skin it
  bar.iconFrame = CreateFrame("Frame", nil, bar)
  bar.iconFrame:SetPoint("RIGHT", bar, "LEFT", -2, 0)
  bar.icon = bar.iconFrame:CreateTexture(nil, "ARTWORK")
  bar.icon:SetAllPoints()
  bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  NF.Skin.Add("Cast Bars", bar.iconFrame, { Icon = bar.icon }, "Action")
  bar.text = bar:CreateFontString(nil, "OVERLAY")
  bar.text:SetPoint("LEFT", 3, 0)
  bar.text:SetJustifyH("LEFT")
  bar.text:SetWordWrap(false)
  -- latency zone: its own layer (a bar's own textures only show over the fill)
  if b.key == "player" then
    bar.latencyLayer = CreateFrame("Frame", nil, bar)
    bar.latencyLayer:SetAllPoints(bar)
    bar.latency = bar.latencyLayer:CreateTexture(nil, "OVERLAY")
    bar.latency:SetTexture(FLAT)
    bar.latency:SetVertexColor(1, 0.15, 0.1, 0.55)
    bar.latency:Hide()
  end
  bar.time = bar:CreateFontString(nil, "OVERLAY")
  bar.time:SetPoint("RIGHT", -3, 0)
  for _, fs in ipairs({ bar.text, bar.time }) do fs:SetShadowOffset(1, -1) end
  bar:Hide()
  bar:SetScript("OnUpdate", onUpdate) -- runs only while a cast is showing
  bar:SetScript("OnEvent", function(self, event)
    local perf = NF.Perf.on
    local t0 = perf and NF.Perf.Now()
    local ok, err = pcall(onEvent, self, event)
    if not ok then NF.Error("castbar " .. tostring(event), err) end
    if perf then NF.Perf.Add("cast bar (" .. b.key .. ")", NF.Perf.Now() - t0) end
  end)
  for _, e in ipairs(EVENTS) do pcall(bar.RegisterUnitEvent, bar, e, b.unit) end
  b.castBar = bar
  CB.Layout(b)
  return bar
end

function CB.Layout(b)
  local bar = b.castBar
  if not bar then return end
  local cfg = NF.profile.frames[b.key]
  local w = cfg.width
  local icon = HEIGHT
  bar:ClearAllPoints()
  bar:SetPoint("TOPLEFT", b, "BOTTOMLEFT", icon + 2, -3)
  bar:SetSize(math.max(20, w - icon - 2), HEIGHT)
  bar.barWidth = math.max(20, w - icon - 2)
  bar.iconFrame:SetSize(icon, icon)
  NF.Skin.Resize(bar.iconFrame)
  local font = NF.Media.Font(NF.profile.general.font)
  bar.text:SetFont(font, 10, "")
  bar.time:SetFont(font, 10, "")
  bar.text:SetWidth(math.max(10, w - icon - 40))
  bar:SetStatusBarTexture(NF.Media.Texture(NF.profile.general.texture))
  b.castBarSpace = cfg.castBar and (HEIGHT + 4) or 0
end

-- Create/refresh for the frames that want one.
function CB.Apply()
  local list = {}
  for _, key in ipairs({ "player", "target" }) do
    if NF.Frames.byKey[key] then list[#list + 1] = NF.Frames.byKey[key] end
  end
  for _, b in ipairs(NF.Boss and NF.Boss.buttons or {}) do list[#list + 1] = b end
  for _, b in ipairs(list) do
    local cfg = NF.profile.frames[b.key]
    if b and cfg.castBar then
      if not b.castBar then CB.Create(b) else CB.Layout(b) end
    elseif b and b.castBar then
      b.castBar:Hide()
      b.castBar:UnregisterAllEvents()
      b.castBar = nil
      b.castBarSpace = 0
    end
  end
end

NF.On("PLAYER_TARGET_CHANGED", function()
  local b = NF.Frames and NF.Frames.byKey.target
  if b and b.castBar then CB.Start(b.castBar) end
end)
