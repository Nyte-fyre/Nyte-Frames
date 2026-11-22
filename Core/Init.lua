-- Init.lua: namespace, event bus, slash commands.
local ADDON, NF = ...
NF.ADDON = ADDON
NF.VERSION = "0.14.0"
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
  local perf = NF.Perf and NF.Perf.on
  local t0 = perf and NF.Perf.Now()
  for i = 1, #list do
    local ok, err = pcall(list[i], event, ...)
    if not ok then NF.Error(event, err) end
  end
  if perf then NF.Perf.Add(event, NF.Perf.Now() - t0) end
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
  print("  /nf role refresh     - re-check everyone's talents (after a respec)")
  print("  /nf probe            - probe status (it records automatically)")
  print("  /nf probe now        - take an out-of-combat snapshot now")
  print("  /nf probe inspect    - inspect your target's talents (role detection test)")
  print("  /nf probe off | on   - stop / resume recording")
  print("  /nf probe reset      - clear everything the probe recorded")
  print("  /nf auras            - status of the Blizzard aura icons on Nyte frames")
  print("  /nf errors           - list Lua errors Nyte Frames caught")
  print("  /nf blizzard         - which Blizzard frames are hidden / showing")
  print("  /nf perf [seconds]   - profile Nyte Frames' CPU use (default 60s)")
  print("  /nf profiles         - profiles window (switch, copy, rename, delete, reset)")
  print("  /nf profile [name]   - show the active profile, or switch to [name]")
  print("  /nf export | import  - share exact settings as a NYTEFRAMES1: string")
  print("Type /reload to save probe data.")
end

commands.config = function() NF.Settings.Toggle() end
commands.unlock = function() NF.EditMode.Unlock() end
commands.role = function(rest) NF.RoleMenu.Command(rest) end
commands.auras = function(rest)
  if (rest or ""):lower() == "dump" then NF.AuraBridge.Dump() else NF.AuraBridge.Report() end
end
commands.lock = function() NF.EditMode.Lock() end
commands.settings = commands.config

commands.errors = function()
  if #NF.errors == 0 then NF.Print("no errors caught this session.") return end
  NF.Print(#NF.errors .. " error(s) this session:")
  for i = 1, math.min(#NF.errors, 10) do print("  " .. NF.errors[i]) end
end

commands.profile = function(rest)
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if rest ~= "" then
    if not NyteFramesDB.profiles[rest] then
      NF.Print("no profile named '" .. rest .. "'. Profiles: " .. table.concat(NF.DB.List(), ", "))
      return
    end
    if InCombatLockdown() then NF.Print("can't switch profiles in combat.") return end
    NF.DB.Use(rest)
    NF.DB.Changed("switched to '" .. rest .. "'")
    NF.Print("now using profile '" .. rest .. "'.")
    return
  end
  NF.Print("profile '" .. NF.DB.ProfileName() .. "', schema " .. tostring(NF.DB.SCHEMA) ..
    (NF.DB.restoredFromCharacter and " (restored from the per-character backup)" or "") ..
    ". Profiles: " .. table.concat(NF.DB.List(), ", "))
end
commands.profiles = function() NF.Profiles.Toggle() end
commands.export = function() NF.Profiles.Show("export") end
commands.import = function() NF.Profiles.Show("import") end

commands.perf = function(rest) NF.Perf.Command(rest) end
commands.blizzard = function()
  NF.Print("Blizzard frames:")
  for _, line in ipairs(NF.Blizzard.Status()) do print(line) end
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
