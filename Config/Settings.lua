-- Settings.lua: standalone settings window (/nf). Milestone 2 covers the
-- player and target frames: enabled, size, power split, text and name color.
-- Widgets are built from plain frames (no option templates) so nothing here
-- depends on Blizzard template changes.
local _, NF = ...
local Settings = {}
NF.Settings = Settings

local FLAT = "Interface\\Buttons\\WHITE8X8"
local window, current
local widgets = {}

Settings.PAGES = {
  { key = "player", label = "Player" },
  { key = "target", label = "Target" },
  { key = "targettarget", label = "ToT" },
  { key = "targettargettarget", label = "ToToT" },
  { key = "party", label = "Party" },
  { key = "raid", label = "Raid" },
}

local function label(parent, text, size)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if size then fs:SetFont(STANDARD_TEXT_FONT, size, "") end
  fs:SetText(text)
  fs:SetJustifyH("LEFT")
  return fs
end

local function flatBG(f, r, g, b, a)
  local t = f:CreateTexture(nil, "BACKGROUND")
  t:SetTexture(FLAT)
  t:SetAllPoints()
  t:SetVertexColor(r, g, b, a)
  return t
end

local function button(parent, text, w, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, 22)
  b.bg = flatBG(b, 0.18, 0.18, 0.22, 1)
  b.text = label(b, text)
  b.text:SetPoint("CENTER")
  b:SetScript("OnEnter", function(self) self.bg:SetVertexColor(0.28, 0.26, 0.38, 1) end)
  b:SetScript("OnLeave", function(self) self:Refresh() end)
  b.Refresh = function(self)
    if self.selected then self.bg:SetVertexColor(0.42, 0.36, 0.75, 1)
    else self.bg:SetVertexColor(0.18, 0.18, 0.22, 1) end
  end
  b:SetScript("OnClick", onClick)
  return b
end

local function checkbox(parent, text, get, set)
  local c = CreateFrame("Button", nil, parent)
  c:SetSize(220, 20)
  c.box = CreateFrame("Frame", nil, c)
  c.box:SetSize(16, 16)
  c.box:SetPoint("LEFT")
  flatBG(c.box, 0.1, 0.1, 0.12, 1)
  c.mark = c.box:CreateTexture(nil, "ARTWORK")
  c.mark:SetTexture(FLAT)
  c.mark:SetPoint("TOPLEFT", 3, -3)
  c.mark:SetPoint("BOTTOMRIGHT", -3, 3)
  c.mark:SetVertexColor(0.55, 0.49, 1, 1)
  c.text = label(c, text)
  c.text:SetPoint("LEFT", c.box, "RIGHT", 6, 0)
  c.Refresh = function(self) self.mark:SetShown(get() and true or false) end
  c:SetScript("OnClick", function(self) set(not get()) self:Refresh() end)
  return c
end

local function slider(parent, text, min, max, step, get, set)
  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(220, 12)
  s:SetMinMaxValues(min, max)
  s:SetValueStep(step)
  s:SetObeyStepOnDrag(true)
  flatBG(s, 0.1, 0.1, 0.12, 1)
  s:SetThumbTexture(FLAT)
  local thumb = s:GetThumbTexture()
  thumb:SetSize(8, 16)
  thumb:SetVertexColor(0.55, 0.49, 1, 1)
  s.label = label(s, text)
  s.label:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
  s.value = label(s, "")
  s.value:SetPoint("LEFT", s, "RIGHT", 8, 0)
  s.Refresh = function(self)
    self.updating = true
    self:SetValue(get())
    self.value:SetText(tostring(get()))
    self.updating = false
  end
  s:SetScript("OnValueChanged", function(self, v)
    if self.updating then return end
    v = math.floor(v / step + 0.5) * step
    self.value:SetText(tostring(v))
    set(v)
  end)
  s:EnableMouseWheel(true)
  s:SetScript("OnMouseWheel", function(self, delta)
    local v = math.max(min, math.min(max, get() + delta * step))
    set(v)
    self:Refresh()
  end)
  return s
end

-- A button that cycles through options and shows the current one.
local function cycle(parent, text, options, get, set)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(300, 22)
  f.label = label(f, text)
  f.label:SetPoint("LEFT")
  f.button = button(f, "", 110, function()
    local cur, idx = get(), 1
    for i, o in ipairs(options) do if o[1] == cur then idx = i end end
    set(options[idx % #options + 1][1])
    f:Refresh()
  end)
  f.button:SetPoint("LEFT", 120, 0)
  f.Refresh = function(self)
    local cur = get()
    for _, o in ipairs(options) do
      if o[1] == cur then self.button.text:SetText(o[2]) end
    end
  end
  return f
end

-- shared with EditMode.lua
Settings.Widgets = { label = label, flatBG = flatBG, button = button, checkbox = checkbox }

---------------------------------------------------------------------------
local function cfg() return NF.profile.frames[current] end

local function changed()
  NF.Frames.Refresh(current)
end

local function build()
  window = CreateFrame("Frame", "NyteFramesSettings", UIParent)
  window:SetSize(500, 545)
  window:SetPoint("CENTER")
  window:SetFrameStrata("DIALOG")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetClampedToScreen(true)
  flatBG(window, 0.05, 0.05, 0.07, 0.96)
  tinsert(UISpecialFrames, "NyteFramesSettings") -- Escape closes it

  local title = label(window, "Nyte Frames  |cff888888v" .. NF.VERSION .. "|r", 14)
  title:SetPoint("TOPLEFT", 14, -12)
  local close = button(window, "X", 22, function() window:Hide() end)
  close:SetPoint("TOPRIGHT", -8, -8)

  -- general section
  local y = -44
  widgets.textMode = cycle(window, "Text (non-player)", { { "percent", "Percent" }, { "number", "Number" }, { "both", "# and %" } },
    function() return NF.profile.general.textMode end,
    function(v) NF.profile.general.textMode = v NF.Frames.Refresh() end)
  widgets.textMode:SetPoint("TOPLEFT", 14, y)
  widgets.abbrev = checkbox(window, "Abbreviate numbers (12.3k)",
    function() return NF.profile.general.abbreviate end,
    function(v) NF.profile.general.abbreviate = v NF.Frames.Refresh() end)
  widgets.abbrev:SetPoint("TOPLEFT", 14, y - 28)
  widgets.blizzAuras = checkbox(window, "Blizzard aura icons (work in combat)",
    function() return NF.profile.general.blizzardAuras end,
    function(v) NF.profile.general.blizzardAuras = v NF.Blizzard.PromptReload() end)
  widgets.blizzAuras:SetPoint("TOPLEFT", 260, y - 28)

  -- page tabs
  local tabs = {}
  for i, page in ipairs(Settings.PAGES) do
    local t = button(window, page.label, 74, function() Settings.Show(page.key) end)
    t:SetPoint("TOPLEFT", 14 + (i - 1) * 78, y - 66)
    t.key = page.key
    tabs[i] = t
  end
  widgets.tabs = tabs

  local py = y - 104
  widgets.enabled = checkbox(window, "Enabled (replaces the Blizzard frame)",
    function() return cfg().enabled end,
    function(v) cfg().enabled = v NF.Blizzard.PromptReload() end)
  widgets.enabled:SetPoint("TOPLEFT", 14, py)

  -- right column: extras for this frame
  local function extra(name, text, get, set, yOff)
    widgets[name] = checkbox(window, text, get, function(v) set(v) changed() end)
    widgets[name]:SetPoint("TOPLEFT", 270, py - yOff)
  end
  extra("castBar", "Cast bar", function() return cfg().castBar end,
    function(v) cfg().castBar = v NF.CastBar.Apply() end, 34)
  extra("buffs", "Buffs", function() return cfg().auras.buffs end,
    function(v) cfg().auras.buffs = v NF.AuraBridge.ScheduleGroup() pcall(NF.AuraBridge.LayoutTarget) end, 56)
  extra("debuffs", "Debuffs", function() return cfg().auras.debuffs end,
    function(v) cfg().auras.debuffs = v NF.AuraBridge.ScheduleGroup() pcall(NF.AuraBridge.LayoutTarget) end, 78)
  extra("healPred", "Incoming heals", function() return cfg().overlays.healPrediction end,
    function(v) cfg().overlays.healPrediction = v end, 100)
  extra("absorbs", "Absorb shields", function() return cfg().overlays.absorbs end,
    function(v) cfg().overlays.absorbs = v end, 122)
  extra("threat", "Threat border", function() return cfg().overlays.threat end,
    function(v) cfg().overlays.threat = v end, 144)
  extra("range", "Fade when out of range", function() return cfg().overlays.rangeFade end,
    function(v) cfg().overlays.rangeFade = v end, 166)
  extra("roleIcon", "Role icon", function() return cfg().icons.role end,
    function(v) cfg().icons.role = v end, 188)
  widgets.auraSize = slider(window, "Aura icon size", 8, 40, 1,
    function() return cfg().auras.size end,
    function(v) cfg().auras.size = v NF.AuraBridge.ScheduleGroup() pcall(NF.AuraBridge.LayoutTarget) end)
  widgets.auraSize:SetPoint("TOPLEFT", 270, py - 232)
  widgets.auraSize:SetWidth(170)
  widgets.auraMax = slider(window, "Max auras", 0, 20, 1,
    function() return cfg().auras.max end,
    function(v) cfg().auras.max = v NF.AuraBridge.ScheduleGroup() pcall(NF.AuraBridge.LayoutTarget) end)
  widgets.auraMax:SetPoint("TOPLEFT", 270, py - 274)
  widgets.auraMax:SetWidth(170)
  widgets.width = slider(window, "Width", 40, 500, 1,
    function() return cfg().width end, function(v) cfg().width = v changed() end)
  widgets.width:SetPoint("TOPLEFT", 14, py - 46)
  widgets.height = slider(window, "Height", 12, 200, 1,
    function() return cfg().height end, function(v) cfg().height = v changed() end)
  widgets.height:SetPoint("TOPLEFT", 14, py - 88)
  widgets.power = slider(window, "Power bar height % (0 hides it)", 0, 50, 1,
    function() return cfg().powerHeightPct end, function(v) cfg().powerHeightPct = v changed() end)
  widgets.power:SetPoint("TOPLEFT", 14, py - 130)
  widgets.frameText = cycle(window, "Text on this frame",
    { { "global", "Use global" }, { "percent", "Percent" }, { "number", "Number" }, { "both", "# and %" } },
    function() return cfg().textMode or "global" end,
    function(v) cfg().textMode = (v ~= "global") and v or nil changed() end)
  widgets.frameText:SetPoint("TOPLEFT", 14, py - 160)
  widgets.nameColor = cycle(window, "Name color",
    { { "white", "White" }, { "class", "Class" }, { "reaction", "Reaction" } },
    function() return cfg().nameColor end, function(v) cfg().nameColor = v changed() end)
  widgets.nameColor:SetPoint("TOPLEFT", 14, py - 188)
  widgets.powerText = checkbox(window, "Show power text",
    function() return cfg().showPowerText end, function(v) cfg().showPowerText = v changed() end)
  widgets.powerText:SetPoint("TOPLEFT", 14, py - 218)
  widgets.reset = button(window, "Reset this frame", 140, function()
    NF.Frames.ResetFrame(current)
    Settings.Show(current)
  end)
  widgets.reset:SetPoint("TOPLEFT", 14, py - 254)
  widgets.unlock = button(window, "Unlock frames", 140, function()
    window:Hide()
    NF.EditMode.Toggle()
  end)
  widgets.unlock:SetPoint("LEFT", widgets.reset, "RIGHT", 10, 0)
  widgets.columns = slider(window, "Raid columns per row (more wrap above)", 1, 8, 1,
    function() return cfg().maxColumnsPerRow or 8 end,
    function(v) cfg().maxColumnsPerRow = v NF.Raid.Apply() end)
  widgets.columns:SetPoint("TOPLEFT", 14, py - 302)

  local note = label(window, "|cff888888Blizzard's target-of-target lives inside its target frame, so it stays hidden while Nyte Target is on. Unlock (/nf unlock) to drag, resize from the corner, nudge with arrow keys and use the grid.|r", 10)
  note:SetPoint("BOTTOMLEFT", 14, 12)
  note:SetWidth(470)
end

function Settings.Show(key)
  if InCombatLockdown() then
    NF.Print("settings open after combat.")
    return
  end
  if not window then build() end
  current = key or current or "player"
  for _, t in ipairs(widgets.tabs) do
    t.selected = (t.key == current)
    t:Refresh()
  end
  for name, w in pairs(widgets) do
    if name ~= "tabs" and w.Refresh then w:Refresh() end
  end
  -- the player frame always shows "# | %"
  widgets.frameText:SetShown(current ~= "player")
  widgets.columns:SetShown(current == "raid")
  local group = (current == "party" or current == "raid")
  widgets.castBar:SetShown(current == "player" or current == "target")
  widgets.range:SetShown(group)
  widgets.roleIcon:SetShown(group)
  local auras = group or current == "target"
  widgets.buffs:SetShown(auras)
  widgets.debuffs:SetShown(auras)
  widgets.auraSize:SetShown(auras)
  widgets.auraMax:SetShown(auras)
  window:Show()
end

function Settings.Toggle()
  if window and window:IsShown() then window:Hide() else Settings.Show() end
end

NF.On("PLAYER_REGEN_DISABLED", function()
  if window and window:IsShown() then window:Hide() end
end)
