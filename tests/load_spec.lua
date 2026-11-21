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
function FrameMethods.SetAlphaFromBoolean(self, v, a, b) self._alphaFromBool = { a, b } end
function FrameMethods.SetVertexColorFromBoolean(self) self._colorFromBool = true end
function FrameMethods.SetVertexColor(self, r, g, b) self._color = { r, g, b } end
function FrameMethods.GetParent(self) return self._parent end
function FrameMethods.GetStatusBarTexture(self) self._fill = self._fill or CreateFrame("Texture") return self._fill end
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
function FrameMethods.GetName(self) return self._name end
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
  if name then _G[name] = o o._name = name end
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
-- Blizzard target aura pools + a raid-style party frame with aura icons
local function iconList(n, parent) local t = {} for i = 1, n do t[i] = CreateFrame("Button") t[i]._parent = parent end return t end
TARGET_BUFFS, TARGET_DEBUFFS = iconList(3, TargetFrame), iconList(2, TargetFrame)
TargetFrame.auraPools = { EnumerateActiveByTemplate = function(self, tpl)
  local list = (tpl == "TargetBuffFrameTemplate") and TARGET_BUFFS or TARGET_DEBUFFS
  local i = 0
  return function() i = i + 1 return list[i] end
end }
function TargetFrame:UpdateAuras() end
CompactPartyFrame = CreateFrame("Frame", "CompactPartyFrame")
CompactPartyFrameMember1 = CreateFrame("Button", "CompactPartyFrameMember1")
CompactPartyFrameMember1.unit = "party1"
CompactPartyFrameMember1.debuffFrames = iconList(3, CompactPartyFrameMember1)
CompactPartyFrameMember1.buffFrames = iconList(3, CompactPartyFrameMember1)
CompactPartyFrameMember1.dispelDebuffFrames = iconList(1, CompactPartyFrameMember1)
function hooksecurefunc(a, b, c)
  if type(a) == "table" then
    local orig = a[b] a[b] = function(...) local r = orig(...) c(...) return r end
  else
    local orig = _G[a] _G[a] = function(...) local r = orig(...) b(...) return r end
  end
end
function CompactUnitFrame_SetUnit() end
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function GetThreatStatusColor(s) if s == 3 then return 1, 0, 0 end return 1, 1, 0 end
TargetFrameToT = CreateFrame("Frame", "TargetFrameToT")
UISpecialFrames = {}
tinsert = table.insert
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
unpack = unpack or table.unpack
watched = {}
function RegisterUnitWatch(f) watched[f] = true end
function UnregisterUnitWatch(f) watched[f] = nil end
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
local NAMES = { player = "Nyte Fyre", party1 = "Zed Pal", party2 = "Amy Priest" }
function GetUnitName(u) return NAMES[u] end
units = { player = true, target = true, party1 = true, party2 = true, targettarget = true, targettargettarget = true }
function UnitExists(u) return units[u] or false end
function UnitName(u) if units[u] then return u == "target" and secret("Mob") or "Nyte", "Fyre" end end
function UnitGUID(u) return units[u] and ("Player-1-" .. u) or nil end
CLASSES = { party2 = "PRIEST" }
function UnitClass(u) if units[u] then local c = CLASSES[u] or "PALADIN" return c, c end end
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
RAID_PLAYER = nil
function UnitIsUnit(a, b) if b == "player" and a == RAID_PLAYER then return true end return a == b end
ROLES = {}
function UnitGroupRolesAssigned(u) return ROLES[u] or "DAMAGER" end
function UnitInRange() return secret(true), true end
THREAT = {}
function UnitThreatSituation(u) return THREAT[u] end
function UnitGetIncomingHeals() return secret(0) end
function UnitGetTotalAbsorbs() return secret(0) end
CASTING = {}
function UnitCastingInfo(u) local c = CASTING[u] if c then return c.name, "", 136243, 0, 0, false, 1, c.notInt end end
function UnitCastingDuration(u) if CASTING[u] then return { GetRemainingDuration = function() return secret(1.2) end } end end
function UnitChannelInfo() return nil end
function GetRaidTargetIndex() return nil end
function UnitIsGroupLeader() return false end
function AbbreviateNumbers(v) return v end
function InCombatLockdown() return inCombat end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return "Elwynn", "none", 0 end
inRaid = false
function IsInRaid() return inRaid end
inGroup = true
function IsInGroup() return inGroup end
groupSize = 2
function GetNumGroupMembers() return groupSize end
function CanInspect() return true end
inspected = {}
function NotifyInspect(u) inspected[#inspected + 1] = u end
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
check(PlayerFrame._parent == ns.Blizzard.hiddenParent and ns.Blizzard.ghosted.TargetFrame and TargetFrame._parent ~= ns.Blizzard.hiddenParent, "player frame hidden, target frame ghosted (kept for its auras)")
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

-- M5: party frames, sorted, above the player frame
local p1, p2, p3, p4 = _G.NyteFrames_Party1, _G.NyteFrames_Party2, _G.NyteFrames_Party3, _G.NyteFrames_Party4
check(p1 and p4, "party pool of 4 created")
check(p1.unit == "party2" and p1.role == "HEALER", "priest (healer) sorted first: " .. tostring(p1.unit))
check(p2.unit == "party1" and p2.role == "DAMAGER", "paladin with no role = DPS second")
check(watched[p1] and watched[p2] and not watched[p3] and not watched[p4], "only filled slots are watched")
check(p1._point.y > p2._point.y, "first member sits on top")
local pc, pl = ns.profile.frames.party, ns.profile.frames.player
check(math.abs((p2._point.x + pc.width / 2) - (pl.pos.x + pl.width / 2)) < 0.01, "column right edge = player right edge " .. p2._point.x .. " " .. pc.width .. " " .. pl.pos.x .. " " .. pl.width .. " " .. tostring(pc.offset.x))
check(math.abs((p2._point.y - pc.height / 2) - (pl.pos.y + pl.height / 2 + pc.spacing)) < 0.01, "column bottom sits on the player frame")
-- manual override flips the order
ns.profile.roleOverrides["Zed Pal"] = "TANK"
fire("GROUP_ROSTER_UPDATE")
check(p1.unit == "party1" and p1.role == "TANK", "override: tank first")
-- roster change in combat is queued
inCombat = true
ns.profile.roleOverrides["Zed Pal"] = nil
fire("GROUP_ROSTER_UPDATE")
check(p1.unit == "party1", "no re-sort in combat")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
check(p1.unit == "party2", "re-sorted after combat")

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
check(ns.profile.frames.player.pos.x == -401, "arrow nudges 1px: " .. ns.profile.frames.player.pos.x)
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
inCombat = false
-- fake party preview when not grouped
check(mv.party ~= nil, "party mover exists")
inGroup = false
fire("GROUP_ROSTER_UPDATE")
ns.EditMode.Unlock()
local fk = ns.EditMode.fakes
check(#fk == 4 and fk[1]._shown and fk[1].name._text == "Brakka" and fk[2].name._text == "Lumen", "fake preview sorted T,H,D,D")
check(not watched[p1] and not watched[p2], "real party buttons released when solo")
-- dragging the party mover moves the group offset
local pm = mv.party
local before = ns.profile.frames.party.offset.x
pm._point.x = pm._point.x - 200
pm._scripts.OnDragStop(pm)
check(ns.profile.frames.party.offset.x <= before - 190, "party drag sets offset: " .. ns.profile.frames.party.offset.x)
ns.EditMode.Lock()
check(not fk[1]._shown, "preview hidden on lock")
inGroup = true

-- M6: raid frames, worked example, roles chain
local RAIDROSTER = {}
function GetRaidRosterInfo(i) local r = RAIDROSTER[i] if r then return r.name, 0, r.sub, 60, r.class, r.class, "", true, false, r.flag end end
local function addRaider(i, name, class, role, sub, flag)
  local u = "raid" .. i
  units[u] = true NAMES[u] = name CLASSES[u] = class ROLES[u] = role
  RAIDROSTER[i] = { name = name, class = class, sub = sub, flag = flag }
end
-- player's group: me + tank, healer, 2 dps
addRaider(1, "Nyte Fyre", "PALADIN", "HEALER", 1) RAID_PLAYER = "raid1"
addRaider(2, "OwnTank", "WARRIOR", "TANK", 1)
addRaider(3, "OwnHeal", "PRIEST", "HEALER", 1)
addRaider(4, "OwnMage", "MAGE", "DAMAGER", 1)
addRaider(5, "OwnRogue", "ROGUE", "DAMAGER", 1)
-- the rest: 3 tanks (one only via the MAINTANK flag), 4 healers, 7 dps
local n = 5
local function add(name, class, role, flag) n = n + 1 addRaider(n, name, class, role, 2 + (n % 3), flag) end
add("T1", "WARRIOR", "TANK") add("T2", "DRUID", "TANK") add("T3", "WARRIOR", "DAMAGER", "MAINTANK")
add("H1", "PRIEST", "HEALER") add("H2", "SHAMAN", "HEALER") add("H3", "DRUID", "HEALER") add("H4", "PALADIN", "HEALER")
for i = 1, 7 do add("D" .. i, (i % 2 == 0) and "MAGE" or "WARLOCK", "DAMAGER") end
inRaid, groupSize = true, n
fire("GROUP_ROSTER_UPDATE")
runTimers()
local cols = {}
for b, e in pairs(ns.Raid.placed) do
  if e then
    cols[e.column] = cols[e.column] or {}
    cols[e.column][e.slot] = (e.member.role or "?"):sub(1, 1)
    check(not e.member.isPlayer, "player never in a raid column")
    check(watched[b], "placed raid button is watched")
  end
end
local function colStr(c) return table.concat(cols[c] or {}) end
check(colStr(1) == "THDD", "raid col 1 = own group: " .. colStr(1))
check(colStr(2) == "TTTHH", "raid col 2: " .. colStr(2))
check(colStr(3) == "HHDDD", "raid col 3: " .. colStr(3))
check(colStr(4) == "DDDD", "raid col 4: " .. colStr(4))
check(not watched[_G.NyteFrames_Party1], "party frames off in a raid")
-- columns step left from the player frame
local r1 = ns.Raid.buttons[1]
local own = {}
for b, e in pairs(ns.Raid.placed) do if e then own[e.column] = own[e.column] or b end end
check(own[2]._point.x < own[1]._point.x and own[3]._point.x < own[2]._point.x, "columns grow left")
-- wrapping: 2 columns per row puts column 3 above column 1
ns.profile.frames.raid.maxColumnsPerRow = 2
ns.Raid.Apply()
local c3
for b, e in pairs(ns.Raid.placed) do if e and e.column == 3 and e.slot == 1 then c3 = e end end
check(c3 and c3.band == 2 and c3.colFromRight == 0, "column 3 wraps above")
ns.profile.frames.raid.maxColumnsPerRow = 8
-- talents via inspect: an unassigned warrior with 31 points in Protection becomes a tank
add("Inspectme", "WARRIOR", "DAMAGER")
groupSize = n
local realNodes = C_Traits.GetNodeInfo
C_Traits.GetNodeInfo = function(_, id) return { ranksPurchased = (id == 2) and 31 or 0, posX = id * 4500 } end
inspected = {}
ns.Roles.INSPECT_GAP = 0
ns.Raid.Apply()
for _ = 1, 40 do
  ns.Roles.Pump()
  local p = ns.Roles.Pending()
  if not p then break end
  fire("INSPECT_READY", p.guid)
end
C_Traits.GetNodeInfo = realNodes
local found
for _, u in ipairs(inspected) do if NAMES[u] == "Inspectme" then found = u end end
check(found ~= nil, "unknown-role warrior gets inspected")
check(found and NyteFramesDB.roleCache[UnitGUID(found)].role == "TANK", "inspect result (31 Prot) cached by GUID as TANK")
check(#inspected > 0 and not (function() for _, u in ipairs(inspected) do if CLASSES[u] == "MAGE" then return true end end end)(), "pure DPS classes are never inspected")
-- manual override via /nf role
SlashCmdList.NYTEFRAMES("role D1 tank")
check(ns.profile.roleOverrides.D1 == "TANK", "/nf role sets override")
SlashCmdList.NYTEFRAMES("role D1 auto")
check(ns.profile.roleOverrides.D1 == nil, "/nf role auto clears it")
check(_G.NyteFrames_Raid1._attr["shift-type2"] == "nfRoleMenu", "shift-right-click opens the role menu")
-- in a raid, unlock previews the raid block
ns.EditMode.Unlock()
check(ns.EditMode.previewMode == "raid" and ns.EditMode.movers.raid and ns.EditMode.movers.raid._shown, "raid mover in a raid")
check(not (ns.EditMode.movers.party and ns.EditMode.movers.party._shown), "party mover hidden in raid mode")
ns.EditMode.Lock()
inRaid = false
ns.EditMode.Unlock()
check(ns.EditMode.previewMode == "party", "solo unlock previews party")
NyteFramesUnlockPanel.preview._scripts.OnClick(NyteFramesUnlockPanel.preview)
local shown = 0
for _, f in ipairs(ns.EditMode.fakes) do if f._shown then shown = shown + 1 end end
check(ns.EditMode.previewMode == "raid" and shown == 24, "fake raid preview shows 24 others: " .. shown)
ns.EditMode.Lock()

-- M7: Blizzard aura bridge, overlays, cast bars
inRaid, groupSize, inGroup = false, 2, true
fire("GROUP_ROSTER_UPDATE")
runTimers() runTimers()
local pbtn
for _, b in ipairs(ns.Party.buttons) do if b.unit == "party1" and ns.Party.placed[b] then pbtn = b end end
check(pbtn ~= nil, "party1 has a Nyte button")
local d1 = CompactPartyFrameMember1.debuffFrames[1]
check(d1._parent == pbtn.textLayer, "Blizzard debuff icon moved onto our party frame")
check(CompactPartyFrameMember1.debuffFrames[3]._parent == pbtn.textLayer, "3 debuffs shown (party max 3)")
check(CompactPartyFrameMember1.buffFrames[1]._parent == ns.Blizzard.hiddenParent, "buffs off on party by default: parked")
check(rawget(CompactPartyFrameMember1, "nfHome") == nil, "no fields written into Blizzard frames")
ns.AuraBridge.Report()
-- target: buttons re-anchored after Blizzard's UpdateAuras
TargetFrame:UpdateAuras()
local tb = _G.NyteFrames_target
check(TARGET_BUFFS[1]._parent == tb and TARGET_DEBUFFS[2]._parent == tb, "target aura buttons follow our target frame")
-- threat border
THREAT.party1 = 3
pbtn._scripts.OnEvent(pbtn, "UNIT_THREAT_SITUATION_UPDATE")
check(pbtn.borders[1]._color[1] == 1 and pbtn.borders[1]._color[2] == 0, "aggro turns the border red")
THREAT.party1 = nil
-- range fade through the secret boolean
pbtn._scripts.OnEvent(pbtn, "UNIT_IN_RANGE_UPDATE")
check(pbtn._alphaFromBool and pbtn._alphaFromBool[2] == ns.profile.general.rangeAlpha, "secret range -> SetAlphaFromBoolean")
-- target cast bar with secret name / not-interruptible flag
check(tb.castBar ~= nil, "target cast bar exists")
CASTING.target = { name = secret("Shadow Bolt"), notInt = secret(true) }
tb.castBar._scripts.OnEvent(tb.castBar, "UNIT_SPELLCAST_START")
check(tb.castBar._shown, "cast bar shows a secret cast")
check(tb.castBar._fill._colorFromBool, "not-interruptible color from the secret flag")
tb.castBar._scripts.OnUpdate(tb.castBar, 0.2)
CASTING.target = nil
tb.castBar._scripts.OnEvent(tb.castBar, "UNIT_SPELLCAST_STOP")
check(not tb.castBar._shown, "cast bar hides when the cast ends")
check(PlayerCastingBarFrame == nil or PlayerCastingBarFrame._parent == ns.Blizzard.hiddenParent, "Blizzard player cast bar hidden")

check(#ns.errors == 0, "addon caught errors: " .. table.concat(ns.errors, " | "))

io.write(string.format("load_spec: %s (%d failure(s))\n", failed == 0 and "ok" or "FAILED", failed))
return failed
