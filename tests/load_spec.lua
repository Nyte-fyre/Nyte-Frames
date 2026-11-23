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
function FrameMethods.SetTextColor(self, r, g, b) self._textColor = { r, g, b } end
function FrameMethods.GetParent(self) return self._parent end
-- like the client: no fill until SetStatusBarTexture, and each call may swap the object
function FrameMethods.GetStatusBarTexture(self) return self._fill end
function FrameMethods.SetStatusBarTexture(self) self._fill = CreateFrame("Texture") end
function FrameMethods.SetTimerDuration() end
function FrameMethods.CreateAnimationGroup(self)
  local g = newObject("AnimationGroup")
  g.CreateAnimation = function() local a = newObject("Animation")
    a.SetOffset = function(a2, x) a2._offset = x end
    a.SetDuration = function(a2, d) a2._dur = d end
    return a end
  g.Play = function(g2, _, offset) g2._playing = true g2._offset = offset or 0 g2._plays = (g2._plays or 0) + 1 end
  g.Stop = function(g2) g2._playing = false end
  g.IsPlaying = function(g2) return g2._playing end
  g.SetScript = function(g2, s, fn) g2._scripts[s] = fn end
  return g
end
function FrameMethods.GetFrameLevel() return 1 end
function FrameMethods.GetHeight(self) return self._h or 768 end
function FrameMethods.GetWidth(self) return self._w or 1024 end
function FrameMethods.SetSize(self, w, h) self._w, self._h = w, h end
function FrameMethods.SetWidth(self, w) self._w = w end
function FrameMethods.SetHeight(self, h) self._h = h end
function FrameMethods.ClearAllPoints(self) self._point = nil self._anchors = {} end
function FrameMethods.SetPoint(self, p, rel, rp, x, y)
  self._anchors = self._anchors or {}
  if type(rel) == "table" then self._anchors[p] = { rel = rel, rp = rp } end
  if type(rel) == "number" then x, y = rel, rp end
  if p == "CENTER" then self._point = { x = x or 0, y = y or 0 } end
end
function FrameMethods.GetCenter(self)
  if self._point then return 512 + self._point.x, 384 + self._point.y end
  return 512, 384
end
function FrameMethods.HasFocus() return false end
function FrameMethods.SetAlpha(self, a) self._alpha = a end
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
function FrameMethods.GetAttribute(self, k) return self._attr and self._attr[k] end
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
CompactPartyFrameMember1._attr = { ["aura-organization-type"] = 2, ["max-buffs"] = 3, ["dispel-indicator-option"] = 1, ["max-dispel-debuffs"] = 4 }
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
BossTargetFrameContainer = CreateFrame("Frame", "BossTargetFrameContainer")
FocusFrame = CreateFrame("Frame", "FocusFrame")
PetFrame = CreateFrame("Frame", "PetFrame")
tinsert = table.insert
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
unpack = unpack or table.unpack
watched = {}
function RegisterUnitWatch(f) watched[f] = true f._shown = true end -- the game shows it while the unit exists
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
Enum = { PowerType = { Mana = 0 },
  RaidDispelDisplayType = { Disabled = 0, DisplayAll = 1, DispellableByMe = 2 },
  RaidDispelOverlayType = { UseDebuffColor = 0, UseBlack = 1 } }
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
TARGET_IS = nil
function UnitIsUnit(a, b) if b == "player" and a == RAID_PLAYER then return true end if b == "target" and a ~= "target" then return a == TARGET_IS end return a == b end
ROLES = {}
function UnitGroupRolesAssigned(u) return ROLES[u] or "DAMAGER" end
function UnitInRange() return secret(true), true end
THREAT = {}
function UnitThreatSituation(u) return THREAT[u] end
function UnitGetIncomingHeals() return secret(0) end
function UnitGetTotalAbsorbs() return secret(0) end
CASTING = {}
function UnitCastingInfo(u) local c = CASTING[u] if c then return c.name, "", 136243, c.startMS or 0, c.endMS or 0, false, 1, c.notInt end end
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
ANCHORS, ANCHOR_N = {}, 0
C_UnitAuras = {
  AddPrivateAuraAnchor = function(args)
    -- like Blizzard: the frame count is fixed now, from the parent's max-* attributes
    args.reserved = { buffs = args.parent._attr and args.parent._attr["max-buffs"],
      debuffs = args.parent._attr and args.parent._attr["max-debuffs"] }
    ANCHOR_PARENTS = ANCHOR_PARENTS or {}
    if ANCHOR_PARENTS[args.parent] then ANCHOR_REUSED = true end
    ANCHOR_PARENTS[args.parent] = true
    ANCHOR_N = ANCHOR_N + 1 ANCHORS[ANCHOR_N] = args return ANCHOR_N end,
  RemovePrivateAuraAnchor = function(id) ANCHORS[id] = nil end,
  GetAuraDataByAuraInstanceID = function(u, id)
    if inCombat then error("Auras cannot be accessed when secret") end
    return { auraInstanceID = id }
  end,
  GetAuraDataByIndex = function(u, i, f)
    if inCombat then error("Auras cannot be accessed when secret") end
    if AURAS and AURAS[u] then return AURAS[u][i] end
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

-- a fake Masque (registered after the TOC's LibStub, before login)
local MASQUE = { groups = {} }
do
  local lib = LibStub:NewLibrary("Masque", 1)
  function lib:Group(addon, name)
    local key = addon .. ": " .. name
    local g = MASQUE.groups[key]
    if g then return g end
    g = { buttons = {}, reskins = 0 }
    function g:AddButton(btn, regions, kind)
      self.buttons[#self.buttons + 1] = { btn = btn, regions = regions, kind = kind }
    end
    function g:ReSkin() self.reskins = self.reskins + 1 end
    MASQUE.groups[key] = g
    return g
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
check(PlayerFrame._parent == ns.Blizzard.hiddenParent and TargetFrame._parent == ns.Blizzard.hiddenParent, "Blizzard player and target frames hidden")
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
check(math.abs((p2._point.y - pc.height / 2) - (pl.pos.y + pl.height / 2 + pc.spacing + pc.offset.y)) < 0.01, "column bottom sits just above the player frame")
check(pc.offset.y > 0 and pc.offset.y <= 18, "default group gap scaled from the reference: " .. pc.offset.y)
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
m._point = { x = -400.4, y = -330.2 }   -- dropped somewhere empty
m._scripts.OnDragStop(m)
local pos = ns.profile.frames.player.pos
check(pos.x == -400 and pos.y == -330, "drag saved as center offset: " .. pos.x .. "," .. pos.y)
m._w, m._h = 150.2, 40
m.grip._scripts.OnMouseUp(m.grip)
check(ns.profile.frames.player.width == 150 and ns.profile.frames.player.height == 40, "corner resize saved")
NyteFramesUnlockPanel._scripts.OnKeyDown(NyteFramesUnlockPanel, "LEFT")
check(ns.profile.frames.player.pos.x == -401, "arrow nudges 1px: " .. ns.profile.frames.player.pos.x)
NyteFramesUnlockPanel._scripts.OnKeyDown(NyteFramesUnlockPanel, "UP")
check(ns.profile.frames.player.pos.y == -329, "arrow up nudges: " .. ns.profile.frames.player.pos.y)
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
-- spec swap: a tank-assigned player who swaps to DPS shows as DPS after a re-inspect
ROLES[found] = "TANK"
check(ns.Roles.Get(found) == "TANK", "assigned tank (talents agree)")
C_Traits.GetNodeInfo = function(_, id) return { ranksPurchased = (id == 2) and 31 or 0, posX = 1000 } end
fire("PLAYER_SPECIALIZATION_CHANGED", found)
check(NyteFramesDB.roleCache[UnitGUID(found)] == nil, "a spec swap forgets the old talents")
for _ = 1, 10 do
  ns.Roles.Pump()
  local p = ns.Roles.Pending()
  if not p then break end
  fire("INSPECT_READY", p.guid)
end
C_Traits.GetNodeInfo = realNodes
local swapped, src = ns.Roles.Get(found)
check(swapped == "DAMAGER" and src == "talents", "after the swap the new talents beat the stale TANK role: " .. tostring(swapped))
fire("ROLE_CHANGED_INFORM", NAMES[found], NAMES[found], "DAMAGER", "TANK")
check(ns.Roles.Get(found) == "TANK", "picking a role again wins over older talents")
ROLES[found] = "DAMAGER"
-- picking Damage in the role menu beats an older Tank talent result
NyteFramesDB.roleCache[UnitGUID(found)] = { role = "TANK", t = time() } -- from an earlier session
fire("ROLE_CHANGED_INFORM", NAMES[found], NAMES[found], "TANK", "DAMAGER")
local picked, psrc = ns.Roles.Get(found)
check(picked == "DAMAGER" and psrc == "picked", "a Damage pick beats an old Tank talent result: " .. tostring(picked))
-- an old-session result gets re-checked once
local q0 = #inspected
add("Respecced", "WARRIOR", "DAMAGER")
groupSize = n
local other = "raid" .. n
if other then
  NyteFramesDB.roleCache[UnitGUID(other)] = { role = "TANK", t = time() }
  ns.Roles.Get(other)
  local hit = false
  for _ = 1, 60 do
    ns.Roles.Pump()
    local p = ns.Roles.Pending()
    if not p then break end
    if p.guid == UnitGUID(other) then hit = true end
    fire("INSPECT_READY", p.guid)
  end
  check(hit, "an old cached result is re-inspected this session")
end
-- /nf role refresh queues everyone
SlashCmdList.NYTEFRAMES("role refresh")
check(ns.Roles.Pending() ~= nil or (function() ns.Roles.Pump() return ns.Roles.Pending() ~= nil end)(), "/nf role refresh starts re-inspecting")
for _ = 1, 60 do
  local p = ns.Roles.Pending()
  if p then fire("INSPECT_READY", p.guid) end
  ns.Roles.Pump()
  if not ns.Roles.Pending() then break end
end
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

-- settings window: no two controls overlap on any page, columns don't collide
do
  local bad = {}
  for _, page in ipairs(ns.Settings.PAGES) do
    ns.Settings.Show(page.key)
    local P = ns.Settings.placed
    if #P < 6 then bad[#bad + 1] = page.key .. ": only " .. #P .. " controls laid out" end
    for i = 1, #P do
      local a = P[i]
      if a.x < ns.Settings.RIGHT_X and a.right > ns.Settings.RIGHT_X - 4 and a.name ~= "reset+unlock" then
        bad[#bad + 1] = page.key .. ": " .. a.name .. " runs into the right column"
      end
      for j = i + 1, #P do
        local b = P[j]
        local xOver = a.x < b.right and b.x < a.right
        local yOver = a.bottom < b.top and b.bottom < a.top
        if xOver and yOver then bad[#bad + 1] = page.key .. ": " .. a.name .. " overlaps " .. b.name end
      end
    end
  end
  check(#bad == 0, "settings pages have no overlapping controls: " .. table.concat(bad, "; "))
  local win = _G.NyteFramesSettings
  check(win._anchors and win._anchors.TOP and not win._point, "settings window is pinned by its top (tabs don't move between pages)")
  win.GetLeft = function() return 300 end
  win.GetTop = function() return 900 end
  win._scripts.OnDragStop(win)
  check(win._anchors.TOPLEFT and win._anchors.TOPLEFT.rp == "BOTTOMLEFT", "after a drag it's pinned by its top-left")
  ns.Settings.Toggle()
end

-- M7: Blizzard aura bridge, overlays, cast bars
inRaid, groupSize, inGroup = false, 2, true
fire("GROUP_ROSTER_UPDATE")
runTimers() runTimers()
local pbtn
for _, b in ipairs(ns.Party.buttons) do if b.unit == "party1" and ns.Party.placed[b] then pbtn = b end end
check(pbtn ~= nil, "party1 has a Nyte button")
local function anchorFor(owner) for id, a in pairs(ANCHORS) do if a.parent._owner == owner then return a, id end end end
local pa = anchorFor(pbtn)
check(pa and pa.isContainer and pa.unitToken == "party1", "party button is a container aura anchor for its unit")
check(pa.parent._attr["max-debuffs"] == 3 and pa.parent._attr["ignore-buffs"] == true, "party: 3 debuffs, buffs off (our settings)")
check(pa.parent._attr["aura-organization-type"] == 2, "Blizzard's own aura settings copied")
-- debuff highlight (Blizzard-drawn, works in combat)
local pat = pa.parent._attr
check(pat["dispel-indicator-option"] == 2 and pat["dispel-indicator-overlay-type"] == 0,
  "party: highlight debuffs I can dispel, in the debuff's color (default)")
check(pat["max-dispel-debuffs"] == 4, "dispel slots use Blizzard's own count (safe size)")
check(pat["display-larger-role-specific-debuffs"] == true and pat["display-only-dispellable-debuffs"] == false,
  "bigger boss debuffs on, all debuffs shown (defaults)")
local hlCfg = ns.profile.frames.party
hlCfg.overlays.dispelMode, hlCfg.overlays.dispelColor, hlCfg.overlays.dispelPulse = "all", "black", true
hlCfg.auras.onlyDispellable = true
ns.AuraBridge.MapGroup() runTimers()
local pat2 = anchorFor(pbtn).parent._attr
check(pat2["dispel-indicator-option"] == 1 and pat2["dispel-indicator-overlay-type"] == 1
  and pat2["dispel-indicator-overlay-animation"] == true and pat2["display-only-dispellable-debuffs"] == true,
  "highlight options reach Blizzard: any type, dark, pulse, only dispellable")
hlCfg.overlays.dispelHighlight = false
ns.AuraBridge.MapGroup() runTimers()
local pat3 = anchorFor(pbtn).parent._attr
check(pat3["dispel-indicator-option"] == 0 and pat3["max-dispel-debuffs"] == 0, "highlight off: Blizzard draws none")
hlCfg.overlays.dispelHighlight, hlCfg.overlays.dispelMode, hlCfg.overlays.dispelColor = true, "mine", "debuff"
hlCfg.overlays.dispelPulse, hlCfg.auras.onlyDispellable = false, false
ns.AuraBridge.MapGroup() runTimers()
local tStripAttr
for _, a in pairs(ANCHORS) do if a.unitToken == "target" then tStripAttr = a.parent._attr end end
check(tStripAttr and tStripAttr["dispel-indicator-option"] == 0, "no dispel tint on the target's icon strip")
check(pa.parent._attr["update-settings"] ~= nil, "settings update signalled")
-- target strip under the frame
local tb = _G.NyteFrames_target
local ta = nil
for _, a in pairs(ANCHORS) do if a.unitToken == "target" then ta = a end end
check(ta and ta.parent ~= tb and ta.parent._attr["max-buffs"] == 16, "target auras on a strip under the target frame")
local pl = nil
for _, a in pairs(ANCHORS) do if a.unitToken == "player" then pl = a end end
check(pl == nil, "player auras off by default (Blizzard buff bar shows them)")
local tick0 = ta.parent._attr["update-settings"]
fire("PLAYER_TARGET_CHANGED")
check(ta.parent._attr["update-settings"] ~= tick0, "a target swap makes Blizzard re-read the target strip (no stale icons)")
-- hybrid buffs: Nyte draws every buff out of combat, Blizzard's in combat
local AB = ns.AuraBridge
fire("PLAYER_REGEN_ENABLED") -- an earlier block left the addon in combat
AURAS = { target = {
  { auraInstanceID = 11, icon = 135964, applications = 1, duration = 3600, expirationTime = 4000, sourceUnit = "party1" },
  { auraInstanceID = 12, icon = 135906, applications = 3, duration = 0, expirationTime = 0, sourceUnit = "target" },
  { auraInstanceID = 13, icon = secret(135907), applications = secret(2), duration = secret(5), expirationTime = secret(9) },
} }
AB.OnAura("target")
local trow = AB.rows.target
check(trow and trow.count == 3 and trow._shown, "out of combat Nyte shows every target buff (others' and self-only too)")
check(trow.icons[2].count._text == "3" and trow.icons[1].count._text == "", "stack counts only above 1")
check(ta.parent._attr["ignore-buffs"] == true and ta.parent._attr["max-buffs"] == 16, "Blizzard skips buffs while Nyte draws them (max-buffs never changes)")
local stripY = ta.parent._owner._anchors and ta.parent._owner._anchors.TOPLEFT
check(stripY ~= nil, "debuff strip re-placed under the buff row")
fire("PLAYER_REGEN_DISABLED")
inCombat = true
AB.OnAura("target")
check(not trow._shown and ta.parent._attr["ignore-buffs"] == false and ta.parent._attr["max-buffs"] == 16,
  "in combat the row hides and Blizzard's buffs come back")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
check(trow._shown and trow.count == 3 and ta.parent._attr["ignore-buffs"] == true, "after combat Nyte's row returns")
AURAS.target = {}
fire("PLAYER_TARGET_CHANGED")
check(not trow._shown and trow.count == 0, "a target with no buffs empties the row")
AURAS = nil
-- re-sort moves the anchor with the unit
local before = ANCHOR_N
ns.profile.roleOverrides["Zed Pal"] = "TANK" fire("GROUP_ROSTER_UPDATE") runTimers() runTimers()
ns.profile.roleOverrides["Zed Pal"] = nil
local pa2 = anchorFor(pbtn)
check(pa2 and pa2.unitToken == pbtn.unit, "after a re-sort the anchor follows the button's new unit")
check(not ANCHOR_REUSED, "each anchor gets a fresh holder frame (no quick reuse)")
local function overReserved()
  for _, a in pairs(ANCHORS) do
    local at = a.parent._attr
    if (at["max-buffs"] or 0) > (a.reserved.buffs or 0) or (at["max-debuffs"] or 0) > (a.reserved.debuffs or 0) then return true end
  end
  return false
end
check(not overReserved(), "no live anchor asks for more icons than Blizzard set aside")
local tStrip = ta.parent._owner
local tHolder = ns.AuraBridge.HolderOf(tStrip)
ns.profile.frames.target.auras.max = 8
ns.AuraBridge.LayoutTarget()
local tHolder2 = ns.AuraBridge.HolderOf(tStrip)
check(tHolder2 ~= tHolder and tHolder2._attr["max-debuffs"] == 8, "changing the icon count makes a new holder")
check(tHolder._attr["max-debuffs"] == 16, "the old holder's limits were never changed")
check(not overReserved(), "still within reserved icons after a settings change")
ns.profile.frames.target.auras.max = 16
ns.AuraBridge.LayoutTarget()
ns.AuraBridge.Report()
-- latency zone on the player cast bar
do
  local pcb = ns.Frames.byKey.player.castBar
  check(pcb and pcb.latency, "player cast bar has a latency zone")
  function GetNetStats() return 0, 0, 40, 150 end
  CASTING.player = { name = "Flash of Light", startMS = 10000, endMS = 11500 }
  ns.CastBar.Start(pcb)
  check(pcb.latency._shown and math.abs(pcb.latencyWidth - pcb.barWidth * 150 / 1500) < 0.01,
    "150ms lag on a 1.5s cast = a tenth of the bar, from world latency")
  check(pcb.latency._anchors.TOPRIGHT and pcb.latency._anchors.TOPRIGHT.rel == pcb.latencyLayer,
    "zone sits at the end of the cast, on its own layer")
  ns.profile.frames.player.castLatency = false
  ns.CastBar.Start(pcb)
  check(not pcb.latency._shown, "latency zone can be turned off")
  ns.profile.frames.player.castLatency = true
  CASTING.player = { name = secret("x"), startMS = secret(1), endMS = secret(2) }
  ns.CastBar.Start(pcb)
  check(not pcb.latency._shown, "secret cast times: no zone, no error")
  CASTING.player = nil
  GetNetStats = nil
  ns.CastBar.Start(pcb)
  local tcb = ns.Frames.byKey.target.castBar
  check(tcb and tcb.latency == nil, "only the player's cast bar gets one")
end
-- border thickness + name colors
do
  local pb3 = ns.Frames.byKey.player
  check(pb3.borders[1]._h == 2 and pb3.borders[3]._w == 2, "border is 2px by default")
  ns.profile.general.borderSize = 3
  ns.UnitButton.Layout(pb3)
  check(pb3.borders[2]._h == 3 and pb3.borders[4]._w == 3, "border follows the setting")
  ns.profile.general.borderSize = 9
  check(ns.UnitButton.BorderSize() == 4, "border is clamped to 4")
  ns.profile.general.borderSize = 2
  ns.UnitButton.Layout(pb3)
  for _, c in ipairs({ { "black", 0, 0, 0 }, { "gold", 1, 0.82, 0 }, { "gray", 0.75, 0.75, 0.75 } }) do
    ns.profile.frames.player.nameColor = c[1]
    ns.UnitButton.UpdateColors(pb3)
    local t = pb3.nameText._textColor
    check(t and t[1] == c[2] and t[2] == c[3] and t[3] == c[4], "name color " .. c[1])
  end
  ns.profile.frames.player.nameColor = "white"
  ns.UnitButton.UpdateColors(pb3)
  local okImp = ns.ImportExport.ValidateProfile
  check(ns.DB.DEFAULTS.general.borderSize == 2, "borderSize is a saved, importable setting")
end
-- mana ticks: found by timing power events, never by reading mana
do
  local MT = ns.ManaTicks
  local pb2 = ns.Frames.byKey.player
  local clock = 500
  MT.Now = function() return clock end
  local function power() MT.OnEvent("UNIT_POWER_UPDATE", "player", "MANA") end
  check(pb2.manaTick and pb2.fiveRule and pb2.manaCost, "player power bar has tick spark, 5s spark and cost shade")
  check(pb2.manaTick.move._dur == 2 and pb2.manaTick.move._offset ~= nil, "tick spark sweeps the bar every 2s")
  check(pb2.manaTick.move._offset == pb2:GetWidth() - 2 * ns.UnitButton.BorderSize(), "the spark sweeps the full bar width, not the mana fill")
  check(pb2.manaLayer ~= nil and pb2.manaTick._anchors.LEFT.rel == pb2.manaLayer, "spark rides its own layer over the bar, not the StatusBar")
  power()                       -- first tick: phase unknown
  check(not MT.state.locked and not pb2.manaTick._shown, "one tick isn't enough to lock the phase")
  clock = 502.05 power()        -- 2s later: locked
  check(MT.state.locked and pb2.manaTick._shown and pb2.manaTick.ag._playing, "two ticks 2s apart lock it and the spark runs")
  clock = 503 power()           -- a gain between ticks (potion): ignored
  check(MT.state.locked and MT.state.lastTick == 502.05, "an extra gain between ticks keeps the phase")
  -- casting a 50-mana spell (max 100) shades half the bar from the fill's edge
  C_Spell.GetSpellPowerCost = function() return { { type = 0, cost = 50 } } end
  clock = 503.5
  MT.OnEvent("UNIT_SPELLCAST_START", "player", "guid", 635)
  local bw = pb2:GetWidth() - 2 * ns.UnitButton.BorderSize()
  check(pb2.manaCost._shown and math.abs((pb2.manaCost._w or 0) - bw / 2) < 0.01, "cast cost shades the right share of the bar")
  check(pb2.manaCost._anchors.TOPRIGHT and pb2.manaCost._anchors.TOPRIGHT.rel == pb2.power:GetStatusBarTexture(), "cost shade ends at the mana fill's edge")
  clock = 505
  MT.OnEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 635)
  check(not pb2.manaCost._shown, "cost shade goes when the cast ends")
  check(pb2.fiveRule._shown and pb2.fiveRule.ag._playing and not pb2.manaTick._shown, "a paid cast starts the 5-second rule spark (tick spark waits)")
  clock = 505.2 power()         -- the cast's own cost: not a tick
  check(MT.state.lastTick == 502.05, "the cast's mana cost isn't counted as a tick")
  clock = 510.2
  pb2.fiveRule.ag._scripts.OnFinished()
  check(not pb2.fiveRule._shown and pb2.manaTick._shown, "after 5s the tick spark is back")
  -- free spell: no 5-second rule
  C_Spell.GetSpellPowerCost = function() return {} end
  MT.OnEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 1)
  check(not pb2.fiveRule._shown, "a free spell doesn't start the 5-second rule")
  -- toggles
  ns.profile.frames.player.manaTicks.ticks = false
  MT.Refresh()
  check(not pb2.manaTick._shown, "tick spark can be turned off")
  ns.profile.frames.player.manaTicks.ticks = true
  MT.Refresh()
  check(next(MT.intervals) ~= nil, "tick intervals are recorded for the probe")
  C_Spell.GetSpellPowerCost = nil
  MT.Now = function() return GetTime() end
end
-- status icon: ready check > summon > incoming res
READY, SUMMON, RES = {}, {}, {}
function GetReadyCheckStatus(u) return READY[u] end
function UnitHasIncomingResurrection(u) return RES[u] end
C_IncomingSummon = { IncomingSummonStatus = function(u) return SUMMON[u] or 0 end }
check(pbtn.statusIcon ~= nil and not pbtn.statusIcon._shown, "status icon hidden with nothing going on")
READY.party1 = "waiting"
fire("READY_CHECK", "Nyte Fyre", 30)
check(pbtn.statusKind == "ready:waiting" and pbtn.statusIcon._shown, "ready check: waiting icon")
READY.party1 = "ready"
fire("READY_CHECK_CONFIRM", "party1", true)
check(pbtn.statusKind == "ready:ready", "ready check: ready icon after confirm")
READY.party1 = "waiting"
fire("READY_CHECK_FINISHED")
check(pbtn.statusKind == "ready:notready", "no answer by the end shows not ready")
READY.party1 = nil
runTimers()
check(pbtn.statusKind == nil and not pbtn.statusIcon._shown, "ready check icons clear a few seconds after it ends")
SUMMON.party1 = 1
RES.party1 = true
ns.UnitButton.Dispatch(pbtn, "INCOMING_SUMMON_CHANGED")
check(pbtn.statusKind == "summon:1", "pending summon beats incoming res")
SUMMON.party1 = 0
ns.UnitButton.Dispatch(pbtn, "INCOMING_SUMMON_CHANGED")
check(pbtn.statusKind == "res", "incoming res icon")
RES.party1 = secret(true)
ns.UnitButton.Dispatch(pbtn, "INCOMING_RESURRECT_CHANGED")
check(pbtn.statusKind == nil, "a secret answer shows nothing (no error)")
RES.party1 = true
ns.profile.frames.party.icons.status = false
ns.UnitButton.Dispatch(pbtn, "INCOMING_RESURRECT_CHANGED")
check(not pbtn.statusIcon._shown, "status icon can be turned off")
ns.profile.frames.party.icons.status = true
RES.party1 = nil
ns.UnitButton.Dispatch(pbtn, "INCOMING_RESURRECT_CHANGED")
-- probe: UNIT_AURA payload readability (part A of debuff highlight)
inCombat = true
fire("PLAYER_REGEN_DISABLED")
fire("UNIT_AURA", "party1", { isFullUpdate = false, addedAuras = { { spellId = secret(589), name = secret("Shadow Word: Pain"),
  auraInstanceID = 99, dispelName = secret("Magic"), isHarmful = true } } })
inCombat = false
fire("PLAYER_REGEN_ENABLED")
local pctx
for ctx, units in pairs(NyteFramesProbeDB.agg) do if ctx:find("^combat") and units.partyN and units.partyN["payloadAura.spellId"] then pctx = units.partyN end end
check(pctx and pctx["payloadAura.spellId"].secret == 1 and pctx["payloadAura.auraInstanceID"].ok == 1,
  "probe records which UNIT_AURA payload fields are secret in combat")
check(pctx and pctx["payload.byInstanceID"] and pctx["payload.byInstanceID"].err == 1, "probe tries the instance id lookup (throws in combat here)")
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

-- M8: boss stack above the target column, target swap
check(BossTargetFrameContainer._parent == ns.Blizzard.hiddenParent, "Blizzard boss frames hidden")
local B = ns.Boss.buttons
check(#B == 5 and watched[B[1]] and watched[B[5]], "5 boss buttons with unit watch")
check(B[1].castBar ~= nil, "boss cast bars")
-- preview when no boss exists
ns.EditMode.Unlock()
check(ns.EditMode.movers.boss and ns.EditMode.movers.boss._shown, "boss stack mover")
ns.EditMode.Lock()
units.boss1, units.boss2, units.boss3 = true, true, true
TARGET_IS = "boss2"
fire("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
check(ns.Boss.slot[B[1]] == 0 and ns.Boss.slot[B[3]] == 1 and ns.Boss.slot[B[2]] == 2, "targeted boss2 leaves the stack, boss3 moves down")
check(B[2]._alpha == ns.Boss.FADED and B[1]._alpha == 1, "targeted boss faded")
check(B[1]._point.y < B[3]._point.y, "stack grows up")
local tcfg = ns.profile.frames.target
local tttTop = ns.profile.frames.targettargettarget.pos.y + ns.profile.frames.targettargettarget.height / 2
check(B[1]._point.y - ns.profile.frames.boss.height / 2 > tttTop, "stack sits above the ToT column")
-- in combat: only the fade changes
inCombat = true
TARGET_IS = "boss3"
fire("PLAYER_TARGET_CHANGED")
check(B[3]._alpha == ns.Boss.FADED and B[2]._alpha == 1, "combat swap = fade")
check(ns.Boss.slot[B[3]] == 1, "no re-pack in combat")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
check(ns.Boss.slot[B[2]] == 1 and ns.Boss.slot[B[3]] == 2, "re-packed after combat")
units.boss1, units.boss2, units.boss3, TARGET_IS = nil, nil, nil, nil

-- M9: import/export + profiles
do
  local IE, DB = ns.ImportExport, ns.DB
  local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
  local function pack(payload, prefix)
    return (prefix or "NYTEFRAMES1:") .. LD:EncodeForPrint(LD:CompressDeflate(LS:Serialize(payload)))
  end
  ns.profile.roleOverrides = { Tanky = "TANK" }
  ns.profile.frames.player.width = 222
  local s = IE.Export(false)
  check(type(s) == "string" and s:find("^NYTEFRAMES1:") ~= nil, "export string is prefixed NYTEFRAMES1:")
  local r, err = IE.Decode(s)
  check(r ~= nil, "own export decodes: " .. tostring(err))
  check(r and r.profile.frames.player.width == 222 and r.profile.frames.player.pos ~= nil, "round trip keeps size and position")
  check(r and next(r.profile.roleOverrides) == nil and not r.hasRoles, "role overrides left out unless asked")
  local r2 = IE.Decode("  " .. IE.Export(true):gsub("(.)", "%1", 1) .. "\n")
  check(r2 and r2.hasRoles and r2.profile.roleOverrides.Tanky == "TANK", "role overrides exported when asked; whitespace ignored")

  ns.profile.frames.party.offset.x = -37
  ns.profile.layout.showGrid = true
  local exact = IE.Decode(IE.Export(true))
  check(exact and IE.Diff(exact) == 0, "export -> import is exact (no setting lost or changed)")
  ns.profile.layout.showGrid = false

  -- rejects, and nothing changes
  local before = DB.Copy(ns.profile)
  local function rejects(str, needle, msg)
    local res, e = IE.Decode(str)
    check(res == nil and type(e) == "string" and (not needle or e:find(needle, 1, true)), msg .. ": " .. tostring(e))
  end
  rejects("hello", "isn't a Nyte Frames string", "wrong prefix rejected")
  rejects("NYTEFRAMES2:abc", "format 2", "newer format rejected")
  rejects("NYTEFRAMES1:" .. s:sub(13, 40), "damaged", "truncated string rejected")
  local bad = DB.Copy(ns.profile) bad.frames.party.width = "wide"
  rejects(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = bad }), "frames.party.width", "wrong type rejected with its path")
  local bad2 = DB.Copy(ns.profile) bad2.frames.raid.maxColumnsPerRow = 99
  rejects(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = bad2 }), "outside", "out-of-range value rejected")
  local bad3 = DB.Copy(ns.profile) bad3.general.textMode = "loud"
  rejects(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = bad3 }), "loud", "unknown enum rejected")
  local bad4 = DB.Copy(ns.profile) bad4.frames.target.pos = { x = 0/0, y = 1 }
  rejects(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = bad4 }), "pos.x", "NaN position rejected")
  rejects(pack({ addon = "NyteFrames", schema = DB.SCHEMA + 1, profile = {} }), "newer Nyte Frames", "newer schema rejected")
  rejects(pack({ addon = "OtherAddon", schema = 1, profile = {} }), "isn't from Nyte Frames", "other addon rejected")
  check(ns.profile.frames.party.width == before.frames.party.width and ns.profile.general.textMode == before.general.textMode, "failed imports change nothing")

  -- unknown keys ignored, missing keys filled, old schema migrated
  local old = { frames = { player = { width = 300, auras = { buffs = true, debuffs = true } }, gizmo = {} },
    general = { sparkle = true }, _schema = 1 }
  local r3 = IE.Decode(pack({ addon = "NyteFrames", schema = 1, profile = old, name = "Old" }))
  check(r3 and r3.dropped == 2, "unknown keys counted and dropped: " .. tostring(r3 and r3.dropped))
  check(r3 and r3.profile.frames.player.auras.buffs == false, "schema 1 import migrated (player auras off)")
  check(r3 and r3.profile.frames.raid.width == DB.DEFAULTS.frames.raid.width and r3.profile.calibrated, "missing settings filled from defaults, marked calibrated")
  check(r3 and IE.Summary(r3):find("upgraded", 1, true), "preview mentions the upgrade")

  -- apply as new profile, then into current
  local mod = DB.Copy(ns.profile) mod.frames.player.width = 250
  local r4 = IE.Decode(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = mod, name = "Shared", hasRoles = false }))
  local total, parts = IE.Diff(r4)
  check(total == 1, "preview diff counts 1 change: " .. tostring(total))
  check(IE.Apply(r4, "new", "Shared"), "apply as new profile")
  check(DB.ProfileName() == "Shared" and ns.profile.frames.player.width == 250, "switched to the imported profile")
  check(ns.profile.roleOverrides.Tanky == "TANK", "own role overrides kept when the string has none")
  check(not IE.Apply(r4, "new", "Shared"), "duplicate profile name refused")
  r4.profile.frames.player.width = 260
  check(IE.Apply(r4, "current") and ns.profile.frames.player.width == 260 and NyteFramesDB.profiles.Shared == ns.profile, "apply into current profile in place")
  inCombat = true
  check(not IE.Apply(r4, "current"), "no import in combat")
  inCombat = false
  runTimers()

  -- profile management
  check(DB.Create("Healer", "Shared") == "Healer" and NyteFramesDB.profiles.Healer.frames.player.width == 260, "copy profile")
  check(DB.Create("Fresh") and NyteFramesDB.profiles.Fresh.frames.player.width == DB.DEFAULTS.frames.player.width, "new profile from defaults")
  check(not DB.Create("Healer"), "create refuses an existing name")
  check(not DB.Create("   "), "create refuses an empty name")
  check(DB.Rename("Shared", "Main") == "Main" and DB.ProfileName() == "Main" and NyteFramesDB.chars[DB.CharKey()] == "Main", "rename the active profile follows the character")
  check(not DB.Delete("Main"), "can't delete the profile in use")
  check(DB.Delete("Fresh") and NyteFramesDB.profiles.Fresh == nil, "delete another profile")
  check(DB.Reset("Main") and ns.profile.frames.player.width == DB.DEFAULTS.frames.player.width and ns.profile.roleOverrides.Tanky == "TANK", "reset keeps role overrides")

  -- window flow
  ns.Profiles.Show("export")
  local exported = ns.Profiles.ui.text.edit:GetText()
  check(exported and exported:find("^NYTEFRAMES1:"), "Export button fills the text box")
  ns.Profiles.ui.text.edit:SetText("junk")
  ns.Profiles.DoCheck()
  check(ns.Profiles.checked == nil and ns.Profiles.ui.status:GetText():find("can't import"), "junk shows an error")
  ns.Profiles.ui.text.edit:SetText(pack({ addon = "NyteFrames", schema = DB.SCHEMA, profile = mod, name = "FromFriend" }))
  ns.Profiles.DoCheck()
  check(ns.Profiles.checked and ns.Profiles.ui.preview:GetText():find("Valid", 1, true), "Check shows a preview")
  ns.Profiles.ui.name:SetText("FromFriend")
  ns.Profiles.DoApply("new")
  check(DB.ProfileName() == "FromFriend", "Save as new from the window")
  StaticPopupDialogs.NYTEFRAMES_DELETE = nil
  SlashCmdList.NYTEFRAMES("profile Main")
  check(DB.ProfileName() == "Main", "/nf profile <name> switches")
  runTimers()
  check(type(NyteFramesDB.profiles.Default) == "table", "Default profile still there")
end

-- M10: Blizzard status, focus/pet, perf, event trimming
do
  check(FocusFrame._parent ~= ns.Blizzard.hiddenParent and PetFrame._parent ~= ns.Blizzard.hiddenParent, "focus/pet off by default: Blizzard's stay")
  check(ns.Frames.byKey.focus == nil, "no Nyte focus frame while off")
  local rows = ns.Blizzard.Status()
  local joined = table.concat(rows, "\n")
  check(joined:find("PlayerFrame (Nyte on): |cff8be28bhidden", 1, true) ~= nil, "status: PlayerFrame hidden")
  check(joined:find("FocusFrame (Nyte off)", 1, true) ~= nil, "status lists FocusFrame as Blizzard's")
  -- Blizzard re-parents a hidden frame: the next check hides it again
  PlayerFrame._parent = UIParent
  fire("EDIT_MODE_LAYOUTS_UPDATED") runTimers()
  check(PlayerFrame._parent == ns.Blizzard.hiddenParent, "re-parented Blizzard frame hidden again")
  -- turning focus on spawns it (after reload) and hides FocusFrame
  ns.profile.frames.focus.enabled = true
  ns.Frames.Spawn() ns.Blizzard.Apply() runTimers()
  check(ns.Frames.byKey.focus ~= nil and FocusFrame._parent == ns.Blizzard.hiddenParent, "focus on: Nyte focus frame, Blizzard's hidden")
  -- hidden buttons skip work; UNIT_FLAGS only redraws on a state change
  local hb
  for _, b in ipairs(ns.Raid.buttons) do if not b._shown then hb = b break end end
  local calls = 0
  local realHealth = ns.UnitButton.UpdateHealth
  ns.UnitButton.Dispatch = (function(orig) return function(...) calls = calls + 1 return orig(...) end end)(ns.UnitButton.Dispatch)
  if hb then hb._scripts.OnEvent(hb, "UNIT_HEALTH") end
  check(hb == nil or calls == 0, "hidden raid button ignores events")
  local pb = ns.Frames.byKey.player
  local full = 0
  local origAll = ns.UnitButton.UpdateAll
  ns.UnitButton.UpdateAll = function(...) full = full + 1 return origAll(...) end
  pb.lastState = nil
  ns.UnitButton.UpdateFlags(pb)
  check(full == 0, "UNIT_FLAGS without a state change does no full redraw")
  pb.lastState = "Dead"
  ns.UnitButton.UpdateFlags(pb)
  check(full == 1, "UNIT_FLAGS after a death/revive redraws")
  ns.UnitButton.UpdateAll = origAll
  check(ns.Overlays.EVENTS.UNIT_HEALTH == nil, "heal/absorb bars don't recompute on every health tick")
  -- heal prediction must hang off the live health fill, not the bar's edge
  local function pinned(btn)
    local a = btn.healPred._anchors or {}
    local fill = btn.health:GetStatusBarTexture()
    return fill ~= nil and a.TOPLEFT and a.TOPLEFT.rel == fill and a.TOPLEFT.rp == "TOPRIGHT"
      and a.BOTTOMLEFT and a.BOTTOMLEFT.rel == fill
      and (btn.absorb._anchors or {}).TOPLEFT and btn.absorb._anchors.TOPLEFT.rel == btn.healPred:GetStatusBarTexture()
  end
  local allPinned = true
  for _, btn in ipairs(ns.UnitButton.all) do if not pinned(btn) then allPinned = false end end
  check(allPinned, "every frame's heal bar starts at the end of its health fill")
  pb.health:SetStatusBarTexture("swap")
  ns.UnitButton.Layout(pb)
  check(pinned(pb), "heal bar re-pins after the health texture is swapped")
  -- profiler
  SlashCmdList.NYTEFRAMES("perf 30")
  check(ns.Perf.on, "/nf perf starts the profiler")
  pb._scripts.OnEvent(pb, "UNIT_HEALTH")
  fire("PLAYER_TARGET_CHANGED")
  SlashCmdList.NYTEFRAMES("perf stop")
  local pr = NyteFramesProbeDB.perf and NyteFramesProbeDB.perf[1]
  check(not ns.Perf.on and pr and pr.calls >= 2, "perf results saved")
  local names = {}
  for _, r in ipairs(pr and pr.rows or {}) do names[r.name] = true end
  check(names["UNIT_HEALTH (player)"] and names.PLAYER_TARGET_CHANGED, "perf rows per event and frame")
  SlashCmdList.NYTEFRAMES("blizzard")
end

-- Masque: our own icons join groups, Blizzard's aura icons don't
do
  local cast = MASQUE.groups["Nyte Frames: Cast Bars"]
  check(cast and #cast.buttons > 0, "cast bar icons are handed to Masque")
  local first = cast and cast.buttons[1]
  check(first and first.regions.Icon and first.btn.nfSkinned == "Cast Bars", "cast icon passes its texture region")
  check(cast and cast.reskins > 0, "cast icons re-skin after layout")
  local buffs = MASQUE.groups["Nyte Frames: Buffs"]
  check(buffs and #buffs.buttons > 0, "buff row icons are handed to Masque")
  local b1 = buffs and buffs.buttons[1]
  check(b1 and b1.regions.Icon and b1.regions.Count and b1.kind == "Buff", "buff icon passes icon/cooldown/count")
  local n = buffs and #buffs.buttons or 0
  ns.Skin.Add("Buffs", b1 and b1.btn, {}, "Buff")
  check(buffs and #buffs.buttons == n, "an icon is only added once")
  -- without Masque nothing breaks
  local real = ns.Skin.Masque
  ns.Skin.Masque, ns.Skin.groups = function() return nil end, {}
  local f = CreateFrame("Frame")
  check(ns.Skin.Add("Buffs", f, {}) == false and not f.nfSkinned, "no Masque: Add is a no-op")
  ns.Skin.Resize(f)
  ns.Skin.Masque = real
end

-- level + Elite / Rare / Boss text on player and target
do
  local UBm = ns.UnitButton
  local tb, pb = ns.Frames.byKey.target, ns.Frames.byKey.player
  local realLevel, realClass = UnitLevel, UnitClassification
  local function plainText(fs) return ((fs._text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local function show(level, class)
    UnitLevel = function(u) if u == "target" then return level end return 60 end
    UnitClassification = function(u) if u == "target" then return class end return "normal" end
    UBm.UpdateAll(tb)
    return plainText(tb.levelText)
  end
  check(ns.profile.frames.player.showLevel and ns.profile.frames.target.showLevel, "level text is on for player and target by default")
  check(not ns.profile.frames.party.showLevel and not ns.profile.frames.targettarget.showLevel, "level text is off on small frames")
  check(show(61, "normal") == "61", "regular mob: level only")
  check(show(61, "trivial") == "61" and show(61, "minus") == "61", "trivial / minus mobs get no tag")
  check(show(62, "elite") == "62 Elite", "elite tag")
  check(show(60, "rare") == "60 Rare", "rare tag")
  check(show(60, "rareelite") == "60 Rare Elite", "rare elite tag")
  check(show(-1, "worldboss") == "?? Boss", "boss: skull level and Boss tag")
  check(show(-1, "elite") == "?? Elite", "skull-level elite")
  check(tb.levelText._shown, "target level text is shown")
  -- colors: elite gold, rare silver, boss red, level by difficulty
  show(62, "elite")
  check(tb.levelText._text:find("|cffffd100Elite|r", 1, true), "elite is gold")
  show(60, "rare")
  check(tb.levelText._text:find("|cffc7c7d9Rare|r", 1, true), "rare is silver")
  show(-1, "worldboss")
  check(tb.levelText._text:find("|cffff4040??|r |cffff4040Boss|r", 1, true), "boss level and tag are red")
  GetCreatureDifficultyColor = function(l) return l >= 65 and { r = 1, g = 0.1, b = 0.1 } or { r = 0.25, g = 0.75, b = 0.25 } end
  show(66, "normal")
  check(tb.levelText._text:find("|cffff1a1a66|r", 1, true), "high level colored by difficulty")
  show(55, "normal")
  check(tb.levelText._text:find("|cff40bf4055|r", 1, true), "low level colored by difficulty")
  GetCreatureDifficultyColor = nil
  -- secret values never error; the text just hides
  UnitLevel = function(u) return secret(60) end
  UnitClassification = function(u) return secret("elite") end
  UBm.UpdateAll(tb)
  check(not tb.levelText._shown and not tb.levelBg._shown, "secret level hides the text and plate")
  -- the name moves right of the level text and gets the rest of the width
  UnitLevel, UnitClassification = function() return 62 end, function() return "elite" end
  tb.levelText.GetStringWidth = function() return 40 end
  UBm.UpdateAll(tb)
  local nameW = tb.nameText._w
  check(tb.levelWidth == 48 and nameW == tb.nameMaxW - 48, "name width shrinks by the level text")
  check(tb.levelBg._shown and tb.levelBg._anchors.TOPLEFT.rel == tb.levelText, "dark plate sits behind the level")
  check(tb.levelBg._color[1] == 0 and tb.levelBg._color[2] == 0, "level plate is black")
  ns.profile.frames.target.showLevel = false
  UBm.Layout(tb)
  check(not tb.levelText._shown and not tb.levelBg._shown and tb.nameText._w == tb.nameMaxW, "turning it off gives the name its width back")
  ns.profile.frames.target.showLevel = true
  tb.levelText.GetStringWidth = nil
  -- events
  UnitLevel = function() return 63 end
  ns.UnitButton.Dispatch(tb, "UNIT_LEVEL")
  check(plainText(tb.levelText) == "63 Elite", "UNIT_LEVEL updates the text")
  UnitClassification = function() return "rare" end
  ns.UnitButton.Dispatch(tb, "UNIT_CLASSIFICATION_CHANGED")
  check(plainText(tb.levelText) == "63 Rare", "UNIT_CLASSIFICATION_CHANGED updates the tag")
  local ev = {}
  for _, e in ipairs(UBm.UNIT_EVENTS) do ev[e] = true end
  check(ev.UNIT_LEVEL and ev.UNIT_CLASSIFICATION_CHANGED, "unit buttons register level / classification events")
  UnitLevel, UnitClassification = realLevel, realClass
  UBm.UpdateAll(pb)
  check(plainText(pb.levelText) == "60", "player shows its level")
  fire("PLAYER_LEVEL_UP", 61)
  UBm.UpdateAll(tb)
  check(plainText(tb.levelText) == "?? Boss", "default mock target is a boss")
end

-- localization: English fallback, a locale file fills L, the template parses
do
  local L = ns.L
  check(L["some string nobody translated"] == "some string nobody translated", "missing translation falls back to English")
  check(ns.NewLocale("deDE") == nil, "other locales' files skip themselves")
  check(ns.NewLocale("enUS") == nil, "English needs no locale file")
  local tpl = readFile(root .. "/Locales/_template.lua")
  local saved = ns.LOCALE
  ns.LOCALE = "xxXX"
  local chunk = loadstring(tpl, "@Locales/_template.lua")
  check(chunk, "translation template is valid Lua")
  if chunk then chunk("NyteFrames", ns) end
  check(rawget(L, "Offline") == "Offline" and rawget(L, "Reset all frames") == "Reset all frames", "template fills every key with itself")
  local n = 0
  for k, v in pairs(L) do
    n = n + 1
    local _, ka = k:gsub("%%[sd]", "")
    local _, va = v:gsub("%%[sd]", "")
    check(ka == va, "placeholders kept: " .. k)
  end
  check(n > 150, "template covers the UI strings (" .. n .. ")")
  -- a real translation shows up in the UI
  rawset(L, "Offline", "Getrennt")
  local printed = {}
  local realPrint = print
  print = function(s) printed[#printed + 1] = s end
  rawset(L, "list Lua errors Nyte Frames caught", "Fehlerliste")
  SlashCmdList.NYTEFRAMES("help")
  print = realPrint
  local found = false
  for _, s in ipairs(printed) do if tostring(s):find("Fehlerliste", 1, true) then found = true end end
  check(found, "slash help uses the translation")
  for k in pairs(L) do rawset(L, k, nil) end
  ns.LOCALE = saved
  check(L["Offline"] == "Offline", "translations cleared after the test")
end

check(#ns.errors == 0, "addon caught errors: " .. table.concat(ns.errors, " | "))

io.write(string.format("load_spec: %s (%d failure(s))\n", failed == 0 and "ok" or "FAILED", failed))
return failed
