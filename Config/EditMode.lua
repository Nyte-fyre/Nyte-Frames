-- EditMode.lua: unlock mode. Each enabled frame gets a mover (a plain,
-- non-secure overlay) that can be dragged, resized from its bottom-right
-- corner, snapped to the grid or to other frames, and nudged with the arrow
-- keys. Moves are saved as CENTER offsets and applied to the secure frames
-- out of combat. Entering is blocked in combat; combat start locks again.
local _, NF = ...
local EditMode = {}
NF.EditMode = EditMode

local FLAT = "Interface\\Buttons\\WHITE8X8"
local LABELS = {
  player = "Player", target = "Target", targettarget = "Target of Target",
  targettargettarget = "ToT's Target", focus = "Focus", pet = "Pet",
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

local function place(m)
  local cfg = NF.profile.frames[m.key]
  local p = cfg.pos or { x = 0, y = 0 }
  m:ClearAllPoints()
  m:SetPoint("CENTER", UIParent, "CENTER", p.x or 0, p.y or 0)
  m:SetSize(cfg.width, cfg.height)
  m.text:SetText(string.format("%s\n|cffbbbbbb%d x %d|r", LABELS[m.key] or m.key, cfg.width, cfg.height))
end

local function rectOf(m)
  local x, y = centerOffset(m)
  return NF.Snap.Rect(x, y, m:GetWidth(), m:GetHeight())
end

-- Save a mover's current spot/size (snapped) to the profile and the real frame.
local function commit(m, resized)
  local others = {}
  for _, o in pairs(movers) do
    if o ~= m and o:IsShown() then others[#others + 1] = rectOf(o) end
  end
  local w, h = round(m:GetWidth()), round(m:GetHeight())
  local x, y = centerOffset(m)
  local nx, ny = NF.Snap.Compute(NF.Snap.Rect(x, y, w, h), others, {
    threshold = 6, grid = layout().grid,
    snapGrid = layout().showGrid, snapElements = layout().snap,
  })
  NF.Frames.SetGeometry(m.key, nx, ny, resized and w or nil, resized and h or nil)
  place(m)
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
  local cfg = NF.profile.frames[selected.key]
  local p = cfg.pos or { x = 0, y = 0 }
  NF.Frames.SetGeometry(selected.key, (p.x or 0) + dx, (p.y or 0) + dy)
  place(selected)
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

  local title = w.label(panel, "Nyte Frames unlocked  |cff888888drag, corner to resize, arrows nudge (Shift = 10)|r")
  title:SetPoint("TOPLEFT", 10, -8)
  local lock = w.button(panel, "Lock", 60, function() EditMode.Lock() end)
  lock:SetPoint("TOPRIGHT", -8, -6)

  panel.grid = w.checkbox(panel, "Grid",
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
  panel.snap = w.checkbox(panel, "Snap to frames",
    function() return layout().snap end, function(v) layout().snap = v end)
  panel.snap:SetPoint("LEFT", plus, "RIGHT", 16, 0)
  panel.snap:SetWidth(130)

  panel.selected = w.label(panel, "")
  panel.selected:SetPoint("TOPLEFT", 10, -62)
  panel.selected:SetWidth(120)
  panel.x = numberBox(panel, function(v)
    if selected then
      local p = NF.profile.frames[selected.key].pos or {}
      NF.Frames.SetGeometry(selected.key, v, p.y or 0) place(selected) EditMode.UpdatePanel()
    end
  end)
  panel.x:SetPoint("TOPLEFT", 136, -60)
  panel.y = numberBox(panel, function(v)
    if selected then
      local p = NF.profile.frames[selected.key].pos or {}
      NF.Frames.SetGeometry(selected.key, p.x or 0, v) place(selected) EditMode.UpdatePanel()
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
  local reset = w.button(panel, "Reset frame", 90, function()
    if selected then NF.Frames.ResetFrame(selected.key) place(selected) EditMode.UpdatePanel() end
  end)
  reset:SetPoint("LEFT", prev, "RIGHT", 8, 0)
  panel.resetAll = w.button(panel, "Reset all frames", 120, function(self)
    if not self.armed then
      self.armed = true
      self.text:SetText("Click to confirm")
      C_Timer.After(3, function() self.armed = false self.text:SetText("Reset all frames") end)
      return
    end
    self.armed = false
    self.text:SetText("Reset all frames")
    for key in pairs(movers) do NF.Frames.ResetFrame(key) end
    for _, m in pairs(movers) do place(m) end
    EditMode.UpdatePanel()
  end)
  panel.resetAll:SetPoint("TOPLEFT", 10, -86)

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
  panel.grid:Refresh()
  panel.snap:Refresh()
  if selected then
    local cfg = NF.profile.frames[selected.key]
    local p = cfg.pos or { x = 0, y = 0 }
    panel.selected:SetText(LABELS[selected.key] or selected.key)
    if not panel.x:HasFocus() then panel.x:SetText(tostring(p.x or 0)) end
    if not panel.y:HasFocus() then panel.y:SetText(tostring(p.y or 0)) end
  else
    panel.selected:SetText("|cff888888click a frame|r")
    panel.x:SetText("")
    panel.y:SetText("")
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
  for key in pairs(NF.Frames.byKey) do
    movers[key] = movers[key] or createMover(key)
    place(movers[key])
    movers[key]:Show()
  end
  EditMode.active = true
  selectMover(selected or movers.player)
  panel:Show()
  updateGrid()
end

function EditMode.Lock()
  EditMode.active = false
  for _, m in pairs(movers) do
    m:StopMovingOrSizing()
    m:Hide()
  end
  if panel then panel:Hide() end
  updateGrid()
end

function EditMode.Toggle()
  if EditMode.active then EditMode.Lock() else EditMode.Unlock() end
end

NF.On("PLAYER_REGEN_DISABLED", function()
  if EditMode.active then
    EditMode.Lock()
    NF.Print("frames locked for combat.")
  end
end)
