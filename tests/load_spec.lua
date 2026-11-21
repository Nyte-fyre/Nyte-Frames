-- Loads the whole addon (TOC order, incl. libs via their XML) against small
-- WoW mocks, then drives login, a fight, slash commands and logout.
-- Fails on any Lua error, any error the addon caught, or a secret value that
-- reached the SavedVariables.
--   python tests/run.py

local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]")) or "."

---------------------------------------------------------------------------
-- Mocks
---------------------------------------------------------------------------
local SECRET_MT = {}
local function secret(v) return setmetatable({ v = v }, SECRET_MT) end
local function bad() error("attempted to use a secret value", 2) end
SECRET_MT.__add, SECRET_MT.__sub, SECRET_MT.__lt, SECRET_MT.__le = bad, bad, bad, bad
SECRET_MT.__concat, SECRET_MT.__eq, SECRET_MT.__index = bad, bad, function() bad() end
function issecretvalue(v) return getmetatable(v) == SECRET_MT end
function issecrettable() return false end

local inCombat = false
local frames = {}
local function newObject(kind)
  local o = { _kind = kind, _scripts = {}, _events = {}, _shown = true }
  return setmetatable(o, { __index = function(t, k)
    if type(k) == "string" and k:match("^[A-Z]") then
      return function() end
    end
    return nil
  end })
end
local FrameMethods = {}
function FrameMethods.RegisterEvent(self, e)
  if e:match("^FAKE") then error("unknown event " .. e) end
  self._events[e] = true
end
function FrameMethods.UnregisterEvent(self, e) self._events[e] = nil end
function FrameMethods.UnregisterAllEvents(self) self._events = {} end
function FrameMethods.SetScript(self, s, fn) self._scripts[s] = fn end
function FrameMethods.GetScript(self, s) return self._scripts[s] end
function FrameMethods.CreateFontString(self) return CreateFrame("FontString") end
function FrameMethods.CreateTexture(self) return CreateFrame("Texture") end
function FrameMethods.IsShown(self) return self._shown end
function FrameMethods.IsProtected() return false, false end
function FrameMethods.GetValue() return 0 end
function FrameMethods.IsTruncated() return false end
function FrameMethods.SetValue(self, v) end
function FrameMethods.SetText(self, v) self._text = v end
function FrameMethods.GetText(self) return self._text end
function FrameMethods.SetAlphaFromBoolean() end
function FrameMethods.SetVertexColorFromBoolean() end
function FrameMethods.SetTimerDuration() end
function FrameMethods.GetFrameLevel() return 1 end
function FrameMethods.GetHeight(self) return self._h or 768 end
function FrameMethods.GetWidth(self) return self._w or 1024 end
function FrameMethods.SetSize(self, w, h) self._w, self._h = w, h end
function FrameMethods.SetWidth(self, w) self._w = w end
function FrameMethods.SetHeight(self, h) self._h = h end
function FrameMethods.ClearAllPoints(self) self._point = nil end
function FrameMethods.SetPoint(self, p, rel, rp, x, y)
  if type(rel) == "number" then x, y = rel, rp end
  if p == "CENTER" then self._point = { x = x or 0, y = y or 0 } end
end
function FrameMethods.GetCenter(self)
  if self._point then return 512 + self._point.x, 384 + self._point.y end
  return 512, 384
end
function FrameMethods.HasFocus() return false end
function FrameMethods.GetThumbTexture(self) self._thumb = self._thumb or CreateFrame("Texture") return self._thumb end
function FrameMethods.Show(self) self._shown = true if self._scripts.OnShow then self._scripts.OnShow(self) end end
function FrameMethods.Hide(self) self._shown = false end
function FrameMethods.SetShown(self, v) if v then self:Show() else self:Hide() end end
function FrameMethods.SetFormattedText(self, fmt, ...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if issecretvalue(v) then self._text = "<secret display>" return end
  end
  self._text = string.format(fmt, ...)
end
function FrameMethods.SetAttribute(self, k, v) self._attr = self._attr or {} self._attr[k] = v end
function FrameMethods.SetParent(self, p) self._parent = p end
function FrameMethods.SetMinMaxValues(self, a, b) self._min, self._max = a, b end
function FrameMethods.SetValue(self, v) self._value = v end

function CreateFrame(kind, name, parent, template)
  if template == "BrokenTemplate" then error("no template") end
  local o = newObject(kind)
  for k, v in pairs(FrameMethods) do o[k] = v end
  frames[#frames + 1] = o
  if name then _G[name] = o end
  return o
end

local function fire(event, ...)
  for _, f in ipairs(frames) do
    if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
  end
end

local timers = {}
C_Timer = {
  After = function(s, fn) timers[#timers + 1] = fn end,
  NewTicker = function(s, fn) local t = { fn = fn, Cancel = function(self) self.dead = true end }
    timers[#timers + 1] = t return t end,
}
local function runTimers()
  local list = timers
  timers = {}
  for _, t in ipairs(list) do
    if type(t) == "function" then t()
    elseif not t.dead then t.fn() timers[#timers + 1] = t end
  end
end

local function bitop(a, b, f)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    if f(a % 2, b % 2) then r = r + p end
    a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
  end
  return r
end
bit = {
  band = function(a, b) return bitop(a, b, function(x, y) return x == 1 and y == 1 end) end,
  bor = function(a, b) return bitop(a, b, function(x, y) return x == 1 or y == 1 end) end,
  bxor = function(a, b) return bitop(a, b, function(x, y) return x ~= y end) end,
  lshift = function(a, n) return a * 2 ^ n end,
  rshift = function(a, n) return math.floor(a / 2 ^ n) end,
}
C_UIFileAsset = { IsKnownFile = function() return true end }
UIParent = CreateFrame("Frame", "UIParent")
PlayerFrame = CreateFrame("Frame", "PlayerFrame")
TargetFrame = CreateFrame("Frame", "TargetFrame")
TargetFrameToT = CreateFrame("Frame", "TargetFrameToT")
UISpecialFrames = {}
tinsert = table.insert
unpack = unpack or table.unpack
watched = {}
function RegisterUnitWatch(f) watched[f] = true end
StaticPopupDialogs = {}
function StaticPopup_Show(name) lastPopup = name end
function ReloadUI() end
function BreakUpLargeNumbers(v) return v end
function UnitIsGhost() return false end
function IsShiftKeyDown() return false end
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
WOW_PROJECT_ID = 1
RAID_CLASS_COLORS = { PALADIN = { r = 0.96, g = 0.55, b = 0.73 } }
CurveConstants = { ScaleTo100 = {} }
Constants = { TraitConsts = { INSPECT_TRAIT_CONFIG_ID = -1 } }
Enum = { PowerType = { Mana = 0 } }
function GetBuildInfo() return "1.60.1", "70205", "Oct 2 2026", 16001 end
function GetLocale() return "enUS" end
function GetTime() return 1000 + os.clock() end
time = os.time
date = os.date
function GetRealmName() return "Realm" end
function GetUnitName(u) return u == "player" and "Nyte Fyre" or nil end
local units = { player = true, target = true, party1 = true, targettarget = true, targettargettarget = true }
function UnitExists(u) return units[u] or false end
function UnitName(u) if units[u] then return u == "target" and secret("Mob") or "Nyte", "Fyre" end end
function UnitGUID(u) return units[u] and ("Player-1-" .. u) or nil end
function UnitClass(u) if units[u] then return "Paladin", "PALADIN" end end
targetIsNPC = true
function UnitIsPlayer(u) return not (u == "target" and targetIsNPC) end
function UnitLevel(u) return u == "target" and -1 or 60 end
function UnitClassification(u) return u == "target" and "worldboss" or "normal" end
function UnitHealth(u) return secret(100) end
function UnitHealthMax(u) return 100 end
function UnitHealthPercent(u) return secret(1) end
function UnitPower(u) return secret(50) end
function UnitPowerMax() return 100 end
function UnitPowerType() return 0, "MANA" end
function UnitIsDeadOrGhost() return false end
function UnitIsConnected() return true end
function UnitReaction() return 2 end
function UnitCanAttack(_, u) return u == "target" end
function UnitIsUnit(a, b) return a == b end
function UnitGroupRolesAssigned() return "DAMAGER" end
function UnitInRange() return secret(true), true end
function UnitThreatSituation() return nil end
function UnitGetIncomingHeals() return secret(0) end
function UnitGetTotalAbsorbs() return secret(0) end
function UnitCastingInfo() return nil end
function UnitChannelInfo() return nil end
function GetRaidTargetIndex() return nil end
function UnitIsGroupLeader() return false end
function AbbreviateNumbers(v) return v end
function InCombatLockdown() return inCombat end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return "Elwynn", "none", 0 end
function IsInRaid() return false end
function IsInGroup() return true end
function GetNumGroupMembers() return 2 end
function CanInspect() return true end
function NotifyInspect() end
function IsEncounterInProgress() return false end
C_UnitAuras = {
  GetAuraDataByIndex = function(u, i, f)
    if inCombat then error("Auras cannot be accessed when secret") end
    return { auraInstanceID = 7, spellId = 1, name = "Buff", duration = 10 }
  end,
}
C_Spell = { IsSpellInRange = function() return true end }
C_ClassTalents = { GetActiveConfigID = function() return 1 end }
C_Traits = {
  GetConfigInfo = function() return { treeIDs = { 9 } } end,
  GetTreeNodes = function() return { 1, 2 } end,
  GetNodeInfo = function(_, id) return { ranksPurchased = id, posX = id * 4000 } end,
}
SlashCmdList = {}
local printed = {}
print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end

---------------------------------------------------------------------------
-- Load files in TOC order
---------------------------------------------------------------------------
local function readFile(p)
  local f = assert(io.open(p, "rb"), "missing " .. p)
  local s = f:read("*a")
  f:close()
  return s
end

local ns = {}
local function loadLua(rel)
  local chunk, err = loadstring(readFile(root .. "/" .. rel), "@" .. rel)
  assert(chunk, err)
  chunk("NyteFrames", ns)
end
local function loadXml(rel)
  local dir = rel:match("^(.*)[/\\]") or ""
  for file in readFile(root .. "/" .. rel):gmatch('<Script%s+file="([^"]+)"') do
    loadLua(dir .. "/" .. file:gsub("\\", "/"))
  end
end
for line in readFile(root .. "/NyteFrames.toc"):gmatch("[^\r\n]+") do
  if not line:match("^%s*#") and line:match("%S") then
    local rel = line:gsub("\\", "/"):gsub("%s+$", "")
    if rel:match("%.xml$") then loadXml(rel) else loadLua(rel) end
  end
end

---------------------------------------------------------------------------
-- Drive it
---------------------------------------------------------------------------
local failed = 0
local function check(cond, msg)
  if not cond then failed = failed + 1 print_ = msg io.write("FAIL " .. msg .. "\n") end
end

fire("ADDON_LOADED", "NyteFrames")
fire("PLAYER_LOGIN")
runTimers()
check(NyteFramesDB and NyteFramesDB.profiles.Default, "default profile created")
check(ns.DB.DEFAULTS.frames.raid.width == 95 and NyteFramesDB.profiles.Default.frames.raid.width > 0, "raid defaults filled")
check(NyteFramesProbeDB and NyteFramesProbeDB.static, "probe static recorded")
check(NyteFramesProbeDB.static.ownTalents and NyteFramesProbeDB.static.ownTalents.total == 3, "own talents bucketed")

-- a fight
inCombat = true
fire("PLAYER_REGEN_DISABLED")
fire("ENCOUNTER_START", 601, "Illidari Council", 4, 25)
fire("UNIT_HEALTH", "party1")
runTimers() runTimers()
inCombat = false
fire("PLAYER_REGEN_ENABLED")
runTimers()
local pdb = NyteFramesProbeDB
check(#pdb.fights == 1, "fight recorded")
check(pdb.fights[1].bossTargets[1] == "<secret>", "secret boss target name recorded as <secret>")
check(pdb.agg["combat@none"] and pdb.agg["combat@none"].player.health.secret > 0, "combat health secret counted")
check(pdb.agg["combat@none"].player.buff1.err > 0, "combat aura error counted")
check(pdb.errs["player.buff1"] ~= nil, "first aura error message kept")

-- inspect flow (target a player now)
targetIsNPC = false
SlashCmdList.NYTEFRAMES("probe inspect")
runTimers() runTimers()
fire("INSPECT_READY", "Player-1-target")
local ins = NyteFramesProbeDB.inspects[1]
check(ins and ins.class == "PALADIN" and ins.guidMatches and ins.talents.total == 3, "inspect recorded")
local disp = NyteFramesProbeDB.static.displayPlayer
check(disp.barSetValueSecret == "ok" and disp.luaArith:match("^err"), "display tests classify")
check(NyteFramesProbeDB.agg["combat@none"].party.health.secret > 0, "party sampled in combat")
check(#NyteFramesProbeDB.events >= 3, "events logged")

for _, cmd in ipairs({ "", "help", "probe", "probe now", "probe off", "probe on", "errors", "profile", "probe reset" }) do
  SlashCmdList.NYTEFRAMES(cmd)
end
fire("PLAYER_LOGOUT")
check(NyteFramesCharDB.backup and NyteFramesCharDB.backup.frames, "per-character backup written")

-- Account file lost (client bug): restored from the character backup
local backup = NyteFramesCharDB
NyteFramesDB = nil
ns.DB.restoredFromCharacter = nil
ns.DB.Init()
check(ns.DB.restoredFromCharacter == true, "restored from character backup")

-- no secret value may reach saved variables
local function scan(t, path, seen)
  seen = seen or {}
  if seen[t] then return end
  seen[t] = true
  for k, v in pairs(t) do
    if issecretvalue(k) or issecretvalue(v) then check(false, "secret saved at " .. path .. "." .. tostring(k)) end
    if type(v) == "table" and not issecretvalue(v) then scan(v, path .. "." .. tostring(k), seen) end
  end
end
scan(NyteFramesProbeDB, "NyteFramesProbeDB")
scan(NyteFramesDB, "NyteFramesDB")

-- M2 frames
local pb, tb = _G.NyteFrames_player, _G.NyteFrames_target
check(pb and tb, "player and target buttons created")
check(pb._attr.unit == "player" and pb._attr["*type2"] == "togglemenu", "secure attributes set")
check(watched[tb] and not watched[pb], "target uses unit watch")
check(pb.healthText._text == "<secret display>", "secret health reached the text via display path: " .. tostring(pb.healthText._text))
check(PlayerFrame._parent == ns.Blizzard.hiddenParent and TargetFrame._parent == ns.Blizzard.hiddenParent, "Blizzard frames hidden")
check(NyteFramesDB.profiles.Default.calibrated and NyteFramesDB.profiles.Default.frames.player.pos, "calibrated")
check(NyteFramesDB.profiles.Default.frames.player.width == math.floor(195 * 768 / 1037 + 0.5), "size scaled to UI")
ns.Settings.Show("target")
check(_G.NyteFramesSettings and _G.NyteFramesSettings._shown, "settings window opens on /nf")
ns.profile.frames.player.powerHeightPct = 0
ns.Frames.Refresh("player")
check(not pb.power._shown, "power 0 hides the power bar")
-- in combat a resize is queued, not applied
inCombat = true
ns.profile.frames.player.width = 300
ns.Frames.Refresh("player")
inCombat = false
fire("PLAYER_REGEN_ENABLED")

-- M3: ToT and ToToT
local tt, ttt = _G.NyteFrames_targettarget, _G.NyteFrames_targettargettarget
check(tt and ttt and watched[tt] and watched[ttt], "ToT and ToToT created with unit watch")
check(tt._scripts.OnUpdate == nil, "ToT is event-driven (no poll)")
check(type(ttt._scripts.OnUpdate) == "function", "ToToT polls")
ttt.healthText._text = nil
ttt._scripts.OnUpdate(ttt, 0.05)
check(ttt.healthText._text == nil, "poll throttled below 0.1s")
ttt._scripts.OnUpdate(ttt, 0.06)
check(ttt.healthText._text ~= nil, "poll updates after 0.1s")
tt.healthText._text = nil
fire("UNIT_TARGET", "target")
check(tt.healthText._text ~= nil, "UNIT_TARGET on target refreshes ToT")
fire("UNIT_TARGET", secret("target"))
check(TargetFrameToT._parent == ns.Blizzard.hiddenParent, "Blizzard ToT hidden")

-- M4: unlock mode
inCombat = true
SlashCmdList.NYTEFRAMES("unlock")
check(not ns.EditMode.active, "unlock refused in combat")
inCombat = false
ns.profile.layout.snap = true
ns.profile.layout.showGrid = false
SlashCmdList.NYTEFRAMES("unlock")
local mv = ns.EditMode.movers
check(ns.EditMode.active and mv.player and mv.target and mv.targettarget and mv.targettargettarget, "movers for every frame")
local m = mv.player
m._scripts.OnMouseDown(m)
m._point = { x = -400.4, y = 100.2 }   -- dropped somewhere empty
m._scripts.OnDragStop(m)
local pos = ns.profile.frames.player.pos
check(pos.x == -400 and pos.y == 100, "drag saved as center offset: " .. pos.x .. "," .. pos.y)
m._w, m._h = 150.2, 40
m.grip._scripts.OnMouseUp(m.grip)
check(ns.profile.frames.player.width == 150 and ns.profile.frames.player.height == 40, "corner resize saved")
NyteFramesUnlockPanel._scripts.OnKeyDown(NyteFramesUnlockPanel, "LEFT")
check(ns.profile.frames.player.pos.x == -401, "arrow nudges 1px")
NyteFramesUnlockPanel._scripts.OnKeyDown(NyteFramesUnlockPanel, "UP")
check(ns.profile.frames.player.pos.y == 101, "arrow up nudges")
-- snap a ToT onto the target's left edge
local tp = ns.profile.frames.target.pos
local tm = mv.targettarget
tm._point = { x = tp.x - ns.profile.frames.target.width / 2 + tm._w / 2 + 3, y = 300 }
tm._scripts.OnDragStop(tm)
local tl = ns.profile.frames.targettarget.pos.x - ns.profile.frames.targettarget.width / 2
local targetLeft = tp.x - ns.profile.frames.target.width / 2
check(math.abs(tl - targetLeft) <= 0.5, "snapped to target's left edge")
ns.profile.layout.showGrid = true
ns.EditMode.Lock() ns.EditMode.Unlock()
check(ns.EditMode.active, "grid on, unlocked again")
fire("PLAYER_REGEN_DISABLED")
check(not ns.EditMode.active and not mv.player._shown, "combat locks")

check(#ns.errors == 0, "addon caught errors: " .. table.concat(ns.errors, " | "))

io.write(string.format("load_spec: %s (%d failure(s))\n", failed == 0 and "ok" or "FAILED", failed))
return failed
