-- Profiles.lua: profile manager + import/export window (/nf profiles).
--
-- Top: profile list (click to select), a name box, and actions on the
-- selected profile: Use, New, Copy, Rename, Delete, Reset.
-- Bottom: one text box for export and import. Import is two steps: Check
-- (decode + validate + preview), then Apply to current or Save as new.
local _, NF = ...
local L = NF.L
local P = {}
NF.Profiles = P

local W = NF.Settings.Widgets
local label, flatBG, button, checkbox = W.label, W.flatBG, W.button, W.checkbox

local window, selected, page = nil, nil, 1
local ui = {}
local PER_PAGE = 10
P.includeRoles = false
P.checked = nil -- last successful import check

local function setEnabled(b, on)
  b:SetEnabled(on and true or false)
  b:SetAlpha(on and 1 or 0.4)
end

local function status(text, isError)
  ui.status:SetText((isError and "|cffff6060" or "|cffcccccc") .. text .. "|r")
end

local function confirm(key, text, onAccept)
  if not (StaticPopupDialogs and StaticPopup_Show) then onAccept() return end
  StaticPopupDialogs[key] = {
    text = text, button1 = YES or L["Yes"], button2 = NO or L["No"],
    OnAccept = onAccept, timeout = 0, whileDead = true, hideOnEscape = true,
  }
  StaticPopup_Show(key)
end

local function nameText()
  return ui.name:GetText() or ""
end

---------------------------------------------------------------------------
-- Profile list
---------------------------------------------------------------------------
function P.RefreshList()
  if not window then return end
  local names = NF.DB.List()
  if not selected or not NyteFramesDB.profiles[selected] then selected = NF.DB.ProfileName() end
  local pages = math.max(1, math.ceil(#names / PER_PAGE))
  page = math.max(1, math.min(page, pages))
  for i, b in ipairs(ui.rows) do
    local name = names[(page - 1) * PER_PAGE + i]
    if name then
      b.name = name
      b.text:SetText(name .. (name == NF.DB.ProfileName() and "  |cff8be28b" .. L["(in use)"] .. "|r" or ""))
      b.selected = (name == selected)
      b:Refresh()
      b:Show()
    else
      b:Hide()
    end
  end
  ui.pageText:SetText(pages > 1 and (page .. "/" .. pages) or "")
  setEnabled(ui.prev, page > 1)
  setEnabled(ui.next, page < pages)
  ui.active:SetText(L["This character uses: %s"]:format("|cffb3a6ff" .. NF.DB.ProfileName() .. "|r"))
  local isActive = selected == NF.DB.ProfileName()
  setEnabled(ui.use, not isActive)
  setEnabled(ui.delete, not isActive)
  setEnabled(ui.apply, P.checked ~= nil)
  setEnabled(ui.saveNew, P.checked ~= nil)
end

local function use(name)
  if InCombatLockdown() then status("can't switch profiles in combat.", true) return end
  NF.DB.Use(name)
  P.checked = nil
  NF.DB.Changed("switched to '" .. name .. "'")
  status(L["now using '%s'."]:format(name))
  P.RefreshList()
end

local function act(fn, okText)
  local ok, err = fn()
  if ok then status(okText) else status(err, true) end
  P.RefreshList()
  return ok
end

---------------------------------------------------------------------------
-- Text box (scrolling, multi-line)
---------------------------------------------------------------------------
local function buildTextBox(parent, w, h)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(w, h)
  flatBG(holder, 0.1, 0.1, 0.12, 1)
  local scroll = CreateFrame("ScrollFrame", nil, holder)
  scroll:SetPoint("TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", -6, 6)
  local eb = CreateFrame("EditBox", nil, scroll)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(0)
  eb:SetWidth(w - 12)
  eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  eb:SetScript("OnEscapePressed", eb.ClearFocus)
  eb:SetScript("OnTextChanged", function(self, user)
    if user and P.checked then
      P.checked = nil
      ui.preview:SetText("")
      P.RefreshList()
    end
  end)
  scroll:SetScrollChild(eb)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local v = math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 24))
    self:SetVerticalScroll(v)
  end)
  holder:EnableMouse(true)
  holder:SetScript("OnMouseDown", function() eb:SetFocus() end)
  holder.edit = eb
  return holder
end

---------------------------------------------------------------------------
-- Export / import actions
---------------------------------------------------------------------------
function P.DoExport()
  local s, err = NF.ImportExport.Export(P.includeRoles)
  if not s then status(err, true) return end
  P.checked = nil
  ui.text.edit:SetText(s)
  ui.text.edit:SetFocus()
  ui.text.edit:HighlightText()
  ui.preview:SetText("")
  status(L["exported '%s' (%d characters). Press Ctrl+C to copy."]:format(NF.DB.ProfileName(), #s))
  P.RefreshList()
end

function P.DoCheck()
  local result, err = NF.ImportExport.Decode(ui.text.edit:GetText())
  P.checked = result
  if not result then
    ui.preview:SetText("")
    status("can't import: " .. err, true)
  else
    ui.preview:SetText(NF.ImportExport.Summary(result))
    if result.name and nameText() == "" then ui.name:SetText(result.name) end
    status(L["looks good. Apply it to the current profile, or save it as a new one."])
  end
  P.RefreshList()
end

function P.DoApply(mode)
  local result = P.checked
  if not result then status(L["check the string first."], true) return end
  if mode == "new" then
    local name, err = NF.DB.ValidName(nameText())
    if not name then status(err, true) return end
    local ok, aerr = NF.ImportExport.Apply(result, "new", name)
    if not ok then status(aerr, true) return end
    status(L["imported as '%s' and switched to it."]:format(name))
  else
    local ok, aerr = NF.ImportExport.Apply(result, "current")
    if not ok then status(aerr, true) return end
    status(L["imported into '%s'."]:format(NF.DB.ProfileName()))
  end
  P.checked = nil
  ui.preview:SetText("")
  P.RefreshList()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function build()
  window = CreateFrame("Frame", "NyteFramesProfiles", UIParent)
  window:SetSize(470, 560)
  window:SetPoint("CENTER", 40, 0)
  window:SetFrameStrata("DIALOG")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetClampedToScreen(true)
  flatBG(window, 0.05, 0.05, 0.07, 0.97)
  tinsert(UISpecialFrames, "NyteFramesProfiles")

  local title = label(window, "Nyte Frames  |cff888888" .. L["Profiles & import/export"] .. "|r", 14)
  title:SetPoint("TOPLEFT", 14, -12)
  local close = button(window, "X", 22, function() window:Hide() end)
  close:SetPoint("TOPRIGHT", -8, -8)

  ui.active = label(window, "")
  ui.active:SetPoint("TOPLEFT", 14, -40)

  -- list: 2 columns x 5 rows
  ui.rows = {}
  for i = 1, PER_PAGE do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local b = button(window, "", 215, function(self)
      selected = self.name
      ui.name:SetText(self.name)
      P.RefreshList()
    end)
    b:SetPoint("TOPLEFT", 14 + col * 222, -60 - row * 24)
    b.text:ClearAllPoints()
    b.text:SetPoint("LEFT", 8, 0)
    ui.rows[i] = b
  end
  ui.prev = button(window, "<", 22, function() page = page - 1 P.RefreshList() end)
  ui.prev:SetPoint("TOPLEFT", 14, -182)
  ui.next = button(window, ">", 22, function() page = page + 1 P.RefreshList() end)
  ui.next:SetPoint("LEFT", ui.prev, "RIGHT", 4, 0)
  ui.pageText = label(window, "")
  ui.pageText:SetPoint("LEFT", ui.next, "RIGHT", 6, 0)

  -- name box
  local nameLabel = label(window, L["Name"])
  nameLabel:SetPoint("TOPLEFT", 120, -186)
  local nameBox = CreateFrame("EditBox", nil, window)
  nameBox:SetSize(200, 20)
  nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
  nameBox:SetAutoFocus(false)
  nameBox:SetMaxLetters(32)
  nameBox:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  nameBox:SetTextInsets(4, 4, 0, 0)
  flatBG(nameBox, 0.1, 0.1, 0.12, 1)
  nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
  nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
  ui.name = nameBox

  -- actions on the selected profile
  local y = -214
  ui.use = button(window, L["Use"], 70, function() use(selected) end)
  ui.use:SetPoint("TOPLEFT", 14, y)
  ui.new = button(window, L["New"], 70, function()
    act(function() return NF.DB.Create(nameText()) end, L["created '%s' from the defaults (select it and press Use)."]:format(nameText()))
  end)
  ui.new:SetPoint("LEFT", ui.use, "RIGHT", 4, 0)
  ui.copy = button(window, L["Copy"], 70, function()
    act(function() return NF.DB.Create(nameText(), selected) end, L["copied '%s' to '%s'."]:format(tostring(selected), nameText()))
  end)
  ui.copy:SetPoint("LEFT", ui.new, "RIGHT", 4, 0)
  ui.rename = button(window, L["Rename"], 70, function()
    local old = selected
    local n, err = NF.DB.Rename(old, nameText())
    if n then selected = n status(L["renamed '%s' to '%s'."]:format(old, n)) else status(err, true) end
    P.RefreshList()
  end)
  ui.rename:SetPoint("LEFT", ui.copy, "RIGHT", 4, 0)
  ui.delete = button(window, L["Delete"], 70, function()
    local name = selected
    confirm("NYTEFRAMES_DELETE", L["Delete the Nyte Frames profile '%s'? This can't be undone."]:format(name), function()
      act(function() return NF.DB.Delete(name) end, L["deleted '%s'."]:format(name))
    end)
  end)
  ui.delete:SetPoint("LEFT", ui.rename, "RIGHT", 4, 0)
  ui.reset = button(window, L["Reset"], 70, function()
    local name = selected
    confirm("NYTEFRAMES_RESET", L["Reset the profile '%s' to the defaults? Role overrides are kept."]:format(name), function()
      if InCombatLockdown() then status("can't reset in combat.", true) return end
      if act(function() return NF.DB.Reset(name) end, L["reset '%s' to the defaults."]:format(name))
          and name == NF.DB.ProfileName() then
        NF.profile.calibrated = nil
        NF.DB.Changed("reset")
      end
    end)
  end)
  ui.reset:SetPoint("LEFT", ui.delete, "RIGHT", 4, 0)

  -- import / export
  local sep = window:CreateTexture(nil, "ARTWORK")
  sep:SetTexture("Interface\\Buttons\\WHITE8X8")
  sep:SetVertexColor(1, 1, 1, 0.08)
  sep:SetPoint("TOPLEFT", 14, -246)
  sep:SetSize(442, 1)
  local ieTitle = label(window, L["Import / export (exact settings)"], 12)
  ieTitle:SetPoint("TOPLEFT", 14, -256)

  ui.roles = checkbox(window, L["Export role overrides too"],
    function() return P.includeRoles end, function(v) P.includeRoles = v end)
  ui.roles:SetPoint("TOPLEFT", 14, -278)
  ui.export = button(window, L["Export current"], 110, P.DoExport)
  ui.export:SetPoint("TOPLEFT", 226, -278)
  ui.check = button(window, L["Check import"], 110, P.DoCheck)
  ui.check:SetPoint("LEFT", ui.export, "RIGHT", 6, 0)

  ui.text = buildTextBox(window, 442, 110)
  ui.text:SetPoint("TOPLEFT", 14, -306)

  ui.preview = label(window, "", 11)
  ui.preview:SetPoint("TOPLEFT", 14, -424)
  ui.preview:SetWidth(442)
  ui.preview:SetJustifyV("TOP")

  ui.apply = button(window, L["Apply to current profile"], 214, function() P.DoApply("current") end)
  ui.apply:SetPoint("BOTTOMLEFT", 14, 36)
  ui.saveNew = button(window, L["Save as new profile (Name)"], 214, function() P.DoApply("new") end)
  ui.saveNew:SetPoint("LEFT", ui.apply, "RIGHT", 14, 0)

  ui.status = label(window, "", 10)
  ui.status:SetPoint("BOTTOMLEFT", 14, 12)
  ui.status:SetWidth(442)
end

function P.Show(mode)
  if InCombatLockdown() then NF.Print(L["profiles open after combat."]) return end
  if not window then build() end
  selected = NF.DB.ProfileName()
  ui.name:SetText("")
  ui.roles:Refresh()
  status(mode == "import" and L["paste a NYTEFRAMES1: string below (Ctrl+V), then press Check import."] or "")
  window:Show()
  P.RefreshList()
  if mode == "export" then P.DoExport()
  elseif mode == "import" then
    ui.text.edit:SetText("")
    ui.preview:SetText("")
    P.checked = nil
    ui.text.edit:SetFocus()
    P.RefreshList()
  end
end

function P.Toggle()
  if window and window:IsShown() then window:Hide() else P.Show() end
end

P.ui = ui -- tests

NF.On("PLAYER_REGEN_DISABLED", function()
  if window and window:IsShown() then window:Hide() end
end)
