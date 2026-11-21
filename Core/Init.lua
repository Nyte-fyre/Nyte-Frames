-- Init.lua: namespace, event bus, slash commands.
local ADDON, NF = ...
NF.ADDON = ADDON
NF.VERSION = "0.6.0"
_G.NyteFrames = NF -- for /dump and other addons; nothing secure reads it

local PREFIX = "|cff8a7dffNyte Frames|r: "
function NF.Print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  print(PREFIX .. table.concat(parts, " "))
end

-- Errors the addon caught itself (pcall'd handlers). Shown by /nf errors and
-- kept in the probe DB so a test session reports them even without BugSack.
NF.errors = {}
function NF.Error(where, err)
  local msg = tostring(where) .. ": " .. tostring(err)
  if #NF.errors < 200 then NF.errors[#NF.errors + 1] = msg end
  if NF.Probe and NF.Probe.RecordError then NF.Probe.RecordError(msg) end
end

---------------------------------------------------------------------------
-- Event bus. Every handler runs in pcall so one broken module can't stop
-- the others. Modules subscribe with NF.On(event, fn) and unsubscribe with
-- NF.Off(event, fn).
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}
NF.eventFrame = frame

function NF.On(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      handlers[event] = nil
      return false
    end
  end
  list[#list + 1] = fn
  return true
end

function NF.Off(event, fn)
  local list = handlers[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
  if #list == 0 then
    handlers[event] = nil
    frame:UnregisterEvent(event)
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], event, ...)
    if not ok then NF.Error(event, err) end
  end
end)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
NF.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  NF.DB.Init()
  NF.Media.Init()
end)

NF.On("PLAYER_LOGIN", function()
  NF.Compat.Run()
  NF.Probe.Start()
  NF.Roles.Init()
  NF.Frames.Spawn()
  NF.Blizzard.Apply()
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local commands = {}
NF.commands = commands

commands.help = function()
  NF.Print("v" .. NF.VERSION .. " commands:")
  print("  /nf                  - open settings")
  print("  /nf unlock | lock    - move and resize frames")
  print("  /nf role [name] tank|healer|dps|auto - set a role (Shift+right-click a frame too)")
  print("  /nf probe            - probe status (it records automatically)")
  print("  /nf probe now        - take an out-of-combat snapshot now")
  print("  /nf probe inspect    - inspect your target's talents (role detection test)")
  print("  /nf probe off | on   - stop / resume recording")
  print("  /nf probe reset      - clear everything the probe recorded")
  print("  /nf errors           - list Lua errors Nyte Frames caught")
  print("  /nf profile          - show the active profile")
  print("Type /reload to save probe data.")
end

commands.config = function() NF.Settings.Toggle() end
commands.unlock = function() NF.EditMode.Unlock() end
commands.role = function(rest) NF.RoleMenu.Command(rest) end
commands.lock = function() NF.EditMode.Lock() end
commands.settings = commands.config

commands.errors = function()
  if #NF.errors == 0 then NF.Print("no errors caught this session.") return end
  NF.Print(#NF.errors .. " error(s) this session:")
  for i = 1, math.min(#NF.errors, 10) do print("  " .. NF.errors[i]) end
end

commands.profile = function()
  NF.Print("profile '" .. NF.DB.ProfileName() .. "', schema " .. tostring(NF.DB.SCHEMA) ..
    (NF.DB.restoredFromCharacter and " (restored from the per-character backup)" or ""))
end

commands.probe = function(rest)
  NF.Probe.Command(rest)
end

local function slash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or "config"
  local fn = commands[cmd] or commands.help
  local ok, err = pcall(fn, rest or "")
  if not ok then
    NF.Error("/nf " .. cmd, err)
    NF.Print("that command hit an error: " .. tostring(err))
  end
end

SLASH_NYTEFRAMES1 = "/nf"
SLASH_NYTEFRAMES2 = "/nyteframes"
SlashCmdList.NYTEFRAMES = slash
