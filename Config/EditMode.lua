-- EditMode.lua: unlock mode. Each enabled frame gets a mover (a plain,
-- non-secure overlay) that can be dragged, resized from its bottom-right
-- corner, snapped to the grid or to other frames, and nudged with the arrow
-- keys. Moves are saved as CENTER offsets and applied to the secure frames
-- out of combat. Entering is blocked in combat; combat start locks again.
local _, NF = ...
local L = NF.L
local EditMode = {}
NF.EditMode = EditMode

local FLAT = "Interface\\Buttons\\WHITE8X8"
local LABELS = {
  player = L["Player"], target = L["Target"], targettarget = L["Target of Target"],
  targettargettarget = L["ToT's Target"], focus = L["Focus"], pet = L["Pet"], party = L["Party"], raid = L["Raid (25-player block)"], boss = L["Boss stack"],
}
local MIN_W, MIN_H, MAX_W, MAX_H = 40, 12, 500, 200

local movers, selected = {}, nil
local panel, grid
EditMode.movers = movers

local function W() return NF.Settings.Widgets end
local function layout() return NF.profile.layout end
local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------
local function centerOffset(f)
  local cx, cy = f:GetCenter()
  local ux, uy = UIParent:GetCenter()
  return cx - ux, cy - uy
end

-- Each mover reads/writes its geometry through get/set: single frames use
-- their saved center; the party mover covers the whole column and moves the
-- group's offset / resizes its cells.
local function geomFor(key)
  if key == "party" then
    return { get = NF.Party.GroupRect, set = NF.Party.SetGroupRect }
  end
  if key == "raid" then
    return { get = NF.Raid.GroupRect, set = NF.Raid.SetGroupRect }
  end
  if key == "boss" then
    return { get = NF.Boss.GroupRect, set = NF.Boss.SetGroupRect }
  end
  return {
    get = function()
      local c = NF.profile.frames[key]
      local p = c.pos or {}
      return p.x or 0, p.y or 0, c.width, c.height
    end,
    set = function(x, y, w, h, resized)
      NF.Frames.SetGeometry(key, x, y, resized and w or nil, resized and h or nil)
    end,
  }
end

local function place(m)
  local x, y, w, h = m.geom.get()
  local cfg = NF.profile.frames[m.key]
  m:ClearAllPoints()
  m:SetPoint("CENTER", UIParent, "CENTER", x, y)
  m:SetSize(w, h)
  m.text:SetText(string.format("%s\n|cffbbbbbb%d x %d|r", LABELS[m.key] or m.key, cfg.width, cfg.height))
end

local function placeAll()
  for _, o in pairs(movers) do
    if o:IsShown() then place(o) end
  end
  EditMode.RefreshPreview()
end

local function rectOf(m)
  local x, y = centerOffset(m)
  return NF.Snap.Rect(x, y, m:GetWidth(), m:GetHeight())
end

-- Save a mover's current spot/size (snapped) to the profile and the real frame.
local function commit(m, resized)
  local others = {}
  for _, o in pairs(movers) do
    -- the party column hangs off the player frame, so it's no snap target for it
    local attached = (m.key == "player" and (o.key == "party" or o.key == "raid"))
      or (o.key == "boss" and (m.key == "target" or m.key == "targettarget" or m.key == "targettargettarget"))
    if o ~= m and o:IsShown() and not attached then others[#others + 1] = rectOf(o) end
  end
  local w, h = round(m:GetWidth()), round(m:GetHeight())
  local x, y = centerOffset(m)
  local nx, ny = NF.Snap.Compute(NF.Snap.Rect(x, y, w, h), others, {
    threshold = 6, grid = layout().grid,
    snapGrid = layout().showGrid, snapElements = layout().snap,
  })
  m.geom.set(nx, ny, w, h, resized)
  placeAll()
  EditMode.UpdatePanel()
end

---------------------------------------------------------------------------
-- Movers
---------------------------------------------------------------------------
local function selectMover(m)
  selected = m
  for _, o in pairs(movers) do
    local c = (o == selected) and { 0.75, 0.68, 1 } or { 0, 0, 0 }
    for _, e in ipairs(o.edges) do e:SetVertexColor(c[1], c[2], c[3], 1) end
  end
  EditMode.UpdatePanel()
end

local function createMover(key)
  local m = CreateFrame("Frame", nil, UIParent)
  m.key = key
  m.geom = geomFor(key)
  m:SetFrameStrata("DIALOG")
  m:SetMovable(true)
  m:SetResizable(true)
  m:SetClampedToScreen(true)
  m:EnableMouse(true)
  m:RegisterForDrag("LeftButton")
  if m.SetResizeBounds then
    m:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
  elseif m.SetMinResize then
    m:SetMinResize(MIN_W, MIN_H)
    m:SetMaxResize(MAX_W, MAX_H)
  end
  local bg = m:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(FLAT)
  bg:SetAllPoints()
  bg:SetVertexColor(0.42, 0.36, 0.75, 0.45)
  m.edges = {}
  for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = m:CreateTexture(nil, "BORDER")
    t:SetTexture(FLAT)
    t:SetPoint(pts[1])
    t:SetPoint(pts[2])
    if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
    t:SetVertexColor(0, 0, 0, 1)
    m.edges[i] = t
  end
  m.text = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  m.text:SetPoint("CENTER")

  m:SetScript("OnMouseDown", function(self) selectMover(self) end)
  m:SetScript("OnDragStart", function(self)
    selectMover(self)
    self:StartMoving()
  end)
  m:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    commit(self, false)
  end)
  m:SetScript("OnSizeChanged", function(self, w, h)
    self.text:SetText(string.format("%s\n|cffbbbbbb%d x %d|r", LABELS[self.key] or self.key, round(w), round(h)))
  end)

  local grip = CreateFrame("Button", nil, m)
  grip:SetSize(12, 12)
  grip:SetPoint("BOTTOMRIGHT", -1, 1)
  local gt = grip:CreateTexture(nil, "OVERLAY")
  gt:SetTexture(FLAT)
  gt:SetAllPoints()
  gt:SetVertexColor(0.85, 0.8, 1, 0.9)
  grip:SetScript("OnMouseDown", function()
    selectMover(m)
    m:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    m:StopMovingOrSizing()
    commit(m, true)
  end)
  m.grip = grip
  return m
end

---------------------------------------------------------------------------
-- Grid
---------------------------------------------------------------------------
local function buildGrid()
  if not grid then
    grid = CreateFrame("Frame", nil, UIParent)
    grid:SetAllPoints(UIParent)
    grid:SetFrameStrata("BACKGROUND")
    grid.lines = {}
  end
  for _, t in ipairs(grid.lines) do t:Hide() end
  local n = 0
  local function line(vertical, offset, center)
    n = n + 1
    local t = grid.lines[n]
    if not t then
      t = grid:CreateTexture(nil, "BACKGROUND")
      t:SetTexture(FLAT)
      grid.lines[n] = t
    end
    t:ClearAllPoints()
    if vertical then
      t:SetPoint("TOP", grid, "TOP", offset, 0)
      t:SetPoint("BOTTOM", grid, "BOTTOM", offset, 0)
      t:SetWidth(1)
    else
      t:SetPoint("LEFT", grid, "LEFT", 0, offset)
      t:SetPoint("RIGHT", grid, "RIGHT", 0, offset)
      t:SetHeight(1)
    end
    if center then t:SetVertexColor(1, 0.3, 0.3, 0.55) else t:SetVertexColor(1, 1, 1, 0.12) end
    t:Show()
  end
  local g = math.max(4, layout().grid or 16)
  local hw, hh = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
  line(true, 0, true)
  line(false, 0, true)
  for o = g, hw, g do line(true, o) line(true, -o) end
  for o = g, hh, g do line(false, o) line(false, -o) end
end

local function updateGrid()
  if layout().showGrid and EditMode.active then
    buildGrid()
    grid:Show()
  elseif grid then
    grid:Hide()
  end
end

---------------------------------------------------------------------------
-- Control panel
---------------------------------------------------------------------------
local function numberBox(parent, onSet)
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(52, 20)
  e:SetAutoFocus(false)
  e:SetFontObject(ChatFontNormal)
  e:SetJustifyH("CENTER")
  W().flatBG(e, 0.12, 0.12, 0.15, 1)
  e:SetScript("OnEnterPressed", function(self)
    local v = tonumber(self:GetText())
    if v then onSet(round(v)) end
    self:ClearFocus()
  end)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() EditMode.UpdatePanel() end)
  return e
end

local function nudge(dx, dy)
  if not selected then return end
  local x, y, w, h = selected.geom.get()
  selected.geom.set(x + dx, y + dy, w, h, false)
  placeAll()
  EditMode.UpdatePanel()
end

local function buildPanel()
  local w = W()
  panel = CreateFrame("Frame", "NyteFramesUnlockPanel", UIParent)
  panel:SetSize(470, 112)
  panel:SetPoint("TOP", 0, -60)
  panel:SetFrameStrata("FULLSCREEN_DIALOG")
  panel:EnableMouse(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving)
  panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
  panel:SetClampedToScreen(true)
  w.flatBG(panel, 0.05, 0.05, 0.07, 0.95)

  local title = w.label(panel, "Nyte Frames " .. L["unlocked"] .. "  |cff888888" .. L["drag, corner to resize, arrows nudge (Shift = 10)"] .. "|r")
  title:SetPoint("TOPLEFT", 10, -8)
  local lock = w.button(panel, L["Lock"], 60, function() EditMode.Lock() end)
  lock:SetPoint("TOPRIGHT", -8, -6)

  panel.grid = w.checkbox(panel, L["Grid"],
    function() return layout().showGrid end,
    function(v) layout().showGrid = v updateGrid() end)
  panel.grid:SetPoint("TOPLEFT", 10, -32)
  panel.grid:SetWidth(60)
  local minus = w.button(panel, "-", 22, function()
    layout().grid = math.max(4, (layout().grid or 16) - 4) EditMode.UpdatePanel() updateGrid() end)
  minus:SetPoint("TOPLEFT", 74, -31)
  panel.gridSize = w.label(panel, "")
  panel.gridSize:SetPoint("LEFT", minus, "RIGHT", 6, 0)
  local plus = w.button(panel, "+", 22, function()
    layout().grid = math.min(64, (layout().grid or 16) + 4) EditMode.UpdatePanel() updateGrid() end)
  plus:SetPoint("LEFT", minus, "RIGHT", 36, 0)
  panel.snap = w.checkbox(panel, L["Snap to frames"],
    function() return layout().snap end, function(v) layout().snap = v end)
  panel.snap:SetPoint("LEFT", plus, "RIGHT", 16, 0)
  panel.snap:SetWidth(130)

  panel.selected = w.label(panel, "")
  panel.selected:SetPoint("TOPLEFT", 10, -62)
  panel.selected:SetWidth(120)
  panel.x = numberBox(panel, function(v)
    if selected then
      local _, y, w, h = selected.geom.get()
      selected.geom.set(v, y, w, h, false) placeAll() EditMode.UpdatePanel()
    end
  end)
  panel.x:SetPoint("TOPLEFT", 136, -60)
  panel.y = numberBox(panel, function(v)
    if selected then
      local x, _, w, h = selected.geom.get()
      selected.geom.set(x, v, w, h, false) placeAll() EditMode.UpdatePanel()
    end
  end)
  panel.y:SetPoint("LEFT", panel.x, "RIGHT", 6, 0)
  local arrows = { { "<", -1, 0 }, { "^", 0, 1 }, { "v", 0, -1 }, { ">", 1, 0 } }
  local prev = panel.y
  for _, a in ipairs(arrows) do
    local b = w.button(panel, a[1], 22, function()
      local step = IsShiftKeyDown() and 10 or 1
      nudge(a[2] * step, a[3] * step)
    end)
    b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    prev = b
  end
  local reset = w.button(panel, L["Reset frame"], 90, function()
    if selected then NF.Frames.ResetFrame(selected.key) placeAll() EditMode.UpdatePanel() end
  end)
  reset:SetPoint("LEFT", prev, "RIGHT", 8, 0)
  panel.resetAll = w.button(panel, L["Reset all frames"], 120, function(self)
    if not self.armed then
      self.armed = true
      self.text:SetText(L["Click to confirm"])
      C_Timer.After(3, function() self.armed = false self.text:SetText(L["Reset all frames"]) end)
      return
    end
    self.armed = false
    self.text:SetText(L["Reset all frames"])
    for key in pairs(movers) do NF.Frames.ResetFrame(key) end
    placeAll()
    EditMode.UpdatePanel()
  end)
  panel.resetAll:SetPoint("TOPLEFT", 10, -86)
  panel.preview = w.button(panel, "", 150, function(self)
    EditMode.previewMode = (EditMode.previewMode == "raid") and "party" or "raid"
    if selected and (selected.key == "party" or selected.key == "raid") then selected = nil end
    EditMode.Unlock()
  end)
  panel.preview:SetPoint("LEFT", panel.resetAll, "RIGHT", 8, 0)

  -- arrow keys nudge the selected frame; Escape locks; other keys pass through
  panel:EnableKeyboard(true)
  panel:SetScript("OnKeyDown", function(self, key)
    local step = IsShiftKeyDown() and 10 or 1
    local handled = true
    if key == "LEFT" then nudge(-step, 0)
    elseif key == "RIGHT" then nudge(step, 0)
    elseif key == "UP" then nudge(0, step)
    elseif key == "DOWN" then nudge(0, -step)
    elseif key == "ESCAPE" then EditMode.Lock()
    else handled = false end
    pcall(self.SetPropagateKeyboardInput, self, not handled)
  end)
end

function EditMode.UpdatePanel()
  if not panel then return end
  panel.gridSize:SetText(tostring(layout().grid or 16))
  panel.preview.text:SetText(L["Showing: %s"]:format((EditMode.previewMode == "raid") and L["Raid"] or L["Party"]))
  panel.grid:Refresh()
  panel.snap:Refresh()
  if selected then
    local x, y = selected.geom.get()
    panel.selected:SetText(LABELS[selected.key] or selected.key)
    if not panel.x:HasFocus() then panel.x:SetText(tostring(round(x))) end
    if not panel.y:HasFocus() then panel.y:SetText(tostring(round(y))) end
  else
    panel.selected:SetText("|cff888888" .. L["click a frame"] .. "|r")
    panel.x:SetText("")
    panel.y:SetText("")
  end
end

---------------------------------------------------------------------------
-- Fake party preview: shown while unlocked when you're not in a party, so the
-- sorting and sizes are visible. Plain frames (not secure, no real units).
---------------------------------------------------------------------------
EditMode.FAKE_PARTY = {   -- deliberately unsorted; the preview sorts it
  { key = "f1", name = "Ember", class = "MAGE", role = "DAMAGER" },
  { key = "f2", name = "Lumen", class = "PRIEST", role = "HEALER" },
  { key = "f3", name = "Vex", class = "ROGUE", role = "DAMAGER" },
  { key = "f4", name = "Brakka", class = "WARRIOR", role = "TANK" },
}
local fakes = {}
EditMode.fakes = fakes

local function fakeFrame(i, pool)
  pool = pool or fakes
  local f = pool[i]
  if f then return f end
  f = CreateFrame("Frame", nil, UIParent)
  f:SetFrameStrata("MEDIUM")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(FLAT)
  bg:SetAllPoints()
  bg:SetVertexColor(0, 0, 0, 1)
  f.bar = f:CreateTexture(nil, "ARTWORK")
  f.bar:SetTexture(FLAT)
  f.bar:SetPoint("TOPLEFT", 1, -1)
  f.power = f:CreateTexture(nil, "ARTWORK")
  f.power:SetTexture(FLAT)
  f.power:SetPoint("BOTTOMLEFT", 1, 1)
  f.power:SetPoint("BOTTOMRIGHT", -1, 1)
  f.power:SetVertexColor(0, 0.45, 0.95, 1)
  f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.name:SetPoint("TOPLEFT", 3, -3)
  f.name:SetJustifyH("LEFT")
  f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.value:SetPoint("BOTTOMRIGHT", -3, 3)
  f.role = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.role:SetPoint("TOPRIGHT", -3, -3)
  pool[i] = f
  return f
end

-- A 25-player fake raid: the player's group (1) plus 20 others with a mix of
-- roles, deliberately unsorted. Built once.
local fakeRaid
local function FakeRaid()
  if fakeRaid then return fakeRaid end
  local classes = { "WARRIOR", "MAGE", "PRIEST", "ROGUE", "DRUID", "HUNTER", "WARLOCK", "SHAMAN", "PALADIN" }
  local roles = { "DAMAGER", "DAMAGER", "HEALER", "DAMAGER", "TANK" }
  fakeRaid = { { key = "me", name = "You", class = "PALADIN", subgroup = 1, isPlayer = true } }
  for i = 1, 24 do
    local cls = classes[(i * 7) % #classes + 1]
    local role = roles[(i * 3) % #roles + 1]
    if cls == "MAGE" or cls == "ROGUE" or cls == "HUNTER" or cls == "WARLOCK" then role = "DAMAGER" end
    if cls == "PRIEST" and role == "TANK" then role = "HEALER" end
    fakeRaid[#fakeRaid + 1] = { key = "r" .. i, name = "Raider" .. i, class = cls, role = role,
      subgroup = math.floor((i) / 5) + 1 }
  end
  return fakeRaid
end
EditMode.FakeRaid = FakeRaid

function EditMode.DefaultPreviewMode()
  return IsInRaid() and "raid" or "party"
end

function EditMode.RefreshPreview()
  local mode = EditMode.previewMode or "party"
  local frames = NF.profile.frames
  local c, placed
  if EditMode.active and mode == "party" and frames.party.enabled and not NF.Party.Active() then
    c = frames.party
    placed = NF.Sorting.Place(NF.Sorting.PartyColumns(EditMode.FAKE_PARTY), 1)
  elseif EditMode.active and mode == "raid" and frames.raid.enabled and not NF.Raid.Active() then
    c = frames.raid
    placed = NF.Sorting.Place(NF.Sorting.RaidColumns(FakeRaid(), 1, 5), c.maxColumnsPerRow or 8, 5)
  end
  placed = placed or {}
  for i = #placed + 1, #fakes do fakes[i]:Hide() end
  EditMode.RefreshBossPreview()
  if not c then return end
  local pct = math.max(0, math.min(60, c.powerHeightPct or 0))
  local textMode = c.textMode or NF.profile.general.textMode
  for i, e in ipairs(placed) do
    local f = fakeFrame(i)
    local x, y = NF.GroupLayout.CellCenter(c, e.colFromRight, e.rowFromBottom)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", x, y)
    f:SetSize(c.width, c.height)
    local powerH = (pct > 0) and math.max(1, math.floor((c.height - 2) * pct / 100 + 0.5)) or 0
    f.power:SetHeight(math.max(1, powerH))
    f.power:SetShown(powerH > 0)
    f.bar:SetPoint("BOTTOMRIGHT", -1, 1 + powerH + (powerH > 0 and 1 or 0))
    f.bar:SetVertexColor(NF.Compat.ClassColor(e.member.class))
    f.name:SetText(e.member.name)
    f.name:SetWidth(math.max(10, c.width - 20))
    f.value:SetText(textMode == "number" and "12.3k" or (textMode == "both" and "12.3k | 100%" or "100%"))
    f.role:SetText(NF.UnitButton.ROLE_LETTER[e.member.role] or "")
    f:Show()
  end
end

-- Boss preview: the Illidari Council, with Gathios as your target (so he's
-- in the main slot = target frame) and the other three in the stack.
EditMode.FAKE_BOSSES = { "High Nethermancer Zerevor", "Lady Malande", "Veras Darkshadow" }
local bossFakes = {}
function EditMode.RefreshBossPreview()
  local c = NF.profile.frames.boss
  local real = NF.Compat.Plain(NF.Compat.Try(UnitExists, "boss1")) == true
  local show = EditMode.active and c.enabled and not real
  for i, name in ipairs(EditMode.FAKE_BOSSES) do
    local f = bossFakes[i]
    if show then
      f = fakeFrame(i, bossFakes)
      local x, y = NF.Boss.SlotCenter(i - 1)
      f:ClearAllPoints()
      f:SetPoint("CENTER", UIParent, "CENTER", x, y)
      f:SetSize(c.width, c.height)
      local pct = math.max(0, math.min(60, c.powerHeightPct or 0))
      local powerH = (pct > 0) and math.max(1, math.floor((c.height - 2) * pct / 100 + 0.5)) or 0
      f.power:SetHeight(math.max(1, powerH))
      f.power:SetShown(powerH > 0)
      f.bar:SetPoint("BOTTOMRIGHT", -1, 1 + powerH + (powerH > 0 and 1 or 0))
      f.bar:SetVertexColor(0.85, 0.2, 0.2)
      f.name:SetText(name)
      f.name:SetWidth(math.max(10, c.width - 40))
      f.value:SetText("100%")
      f.role:SetText("")
      f:Show()
    elseif f then
      f:Hide()
    end
  end
end

---------------------------------------------------------------------------
-- Enter / leave
---------------------------------------------------------------------------
function EditMode.Unlock()
  if InCombatLockdown() then
    NF.Print("can't unlock in combat.")
    return
  end
  if not panel then buildPanel() end
  local keys = {}
  for key in pairs(NF.Frames.byKey) do keys[#keys + 1] = key end
  EditMode.previewMode = EditMode.previewMode or EditMode.DefaultPreviewMode()
  for _, m in pairs(movers) do m:Hide() end
  -- party and raid sit in the same spot: one at a time, switched on the panel
  local group = EditMode.previewMode
  if NF.profile.frames[group].enabled then keys[#keys + 1] = group end
  if NF.profile.frames.boss.enabled then keys[#keys + 1] = "boss" end
  for _, key in ipairs(keys) do
    movers[key] = movers[key] or createMover(key)
    movers[key]:Show()
  end
  EditMode.active = true
  placeAll()
  selectMover(selected or movers.player)
  panel:Show()
  updateGrid()
end

function EditMode.Lock()
  EditMode.active = false
  EditMode.previewMode = nil -- next unlock picks party/raid from your group
  for _, m in pairs(movers) do
    m:StopMovingOrSizing()
    m:Hide()
  end
  if panel then panel:Hide() end
  updateGrid()
  EditMode.RefreshPreview()
end

function EditMode.Toggle()
  if EditMode.active then EditMode.Lock() else EditMode.Unlock() end
end

NF.On("PLAYER_REGEN_DISABLED", function()
  if EditMode.active then
    EditMode.Lock()
    NF.Print(L["frames locked for combat."])
  end
end)
