-- Roles.lua: resolve TANK / HEALER / DAMAGER for a group member.
--
-- Chain (handoff section 5), first answer wins:
--   1. manual override (profile.roleOverrides, by character name)
--   2. UnitGroupRolesAssigned, TANK/HEALER only: this client reports DAMAGER
--      for anyone without a role set (probe #1), so DAMAGER isn't trusted
--   3. raid roster: main tank flag (GetRaidRosterInfo)
--   4. talents, read by inspecting the player (cached per GUID)
--   5. class heuristic: Priest = healer, everyone else = DPS
--
-- Inspects run out of combat only, one at a time, rate limited, never while
-- the inspect window is open. If the client ever blocks NotifyInspect from a
-- timer, automatic inspecting switches itself off for the session.
local _, NF = ...
local Roles = {}
NF.Roles = Roles

local Plain, Try = NF.Compat.Plain, NF.Compat.Try
local RoleRules = NF.RoleRules

Roles.CLASS_DEFAULT = { PRIEST = "HEALER" }
Roles.INSPECT_GAP = 2       -- seconds between inspects
Roles.INSPECT_TIMEOUT = 5
Roles.CACHE_DAYS = 14

Roles.autoInspect = true
local queue, queued, pending = {}, {}, nil
local lastInspect = 0
local roster = {}           -- [unit] = { mainTank = bool } from the last roster scan

local function cache()
  NyteFramesDB.roleCache = NyteFramesDB.roleCache or {}
  return NyteFramesDB.roleCache
end

function Roles.NameOf(unit)
  local n = Plain(Try(GetUnitName, unit, true))
  if type(n) == "string" then return (n:gsub("%-.*$", "")) end
  return nil
end

local function guidOf(unit)
  local g = Plain(Try(UnitGUID, unit))
  return type(g) == "string" and g or nil
end

local function classOf(unit)
  local ok, _, class = pcall(UnitClass, unit)
  return ok and Plain(class) or nil
end

-- returns role, source
function Roles.Get(unit)
  local name = Roles.NameOf(unit)
  local overrides = NF.profile and NF.profile.roleOverrides
  if name and overrides and overrides[name] then return overrides[name], "override" end
  local assigned = NF.Compat.Role(unit)
  if assigned == "TANK" or assigned == "HEALER" then return assigned, "assigned" end
  if roster[unit] and roster[unit].mainTank then return "TANK", "roster" end
  local guid = guidOf(unit)
  local c = guid and NyteFramesDB and cache()[guid]
  if c and c.role then return c.role, "talents" end
  local class = classOf(unit)
  if class and RoleRules.TREES[class] == nil then return "DAMAGER", "class" end
  if guid and Roles.autoInspect then Roles.Queue(unit) end
  if class and Roles.CLASS_DEFAULT[class] then return Roles.CLASS_DEFAULT[class], "class" end
  return "DAMAGER", "default"
end

-- Raid roster flags (main tank). Called before a raid re-sort.
function Roles.ScanRoster()
  wipe(roster)
  if not (IsInRaid() and GetRaidRosterInfo) then return end
  for i = 1, GetNumGroupMembers() do
    local ok, _, _, _, _, _, _, _, _, _, role = pcall(GetRaidRosterInfo, i)
    if ok and Plain(role) == "MAINTANK" then roster["raid" .. i] = { mainTank = true } end
  end
end

---------------------------------------------------------------------------
-- Inspect queue
---------------------------------------------------------------------------
function Roles.Queue(unit)
  local guid = guidOf(unit)
  if not guid or queued[guid] then return end
  queued[guid] = true
  queue[#queue + 1] = { unit = unit, guid = guid }
end

local function inspectBuckets()
  local id = Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID or -1
  local info = C_Traits.GetConfigInfo(id)
  if not info or not info.treeIDs then return nil end
  local buckets = {}
  for _, treeID in ipairs(info.treeIDs) do
    for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
      local n = C_Traits.GetNodeInfo(id, nodeID)
      local ranks, x = n and Plain(n.ranksPurchased), n and Plain(n.posX)
      if type(ranks) == "number" and ranks > 0 and type(x) == "number" then
        local b = math.floor(x / 1000)
        buckets[b] = (buckets[b] or 0) + ranks
      end
    end
  end
  return buckets
end

local function inspectWindowOpen()
  return InspectFrame and InspectFrame.IsShown and InspectFrame:IsShown()
end

function Roles.Pending() return pending end -- for tests / debugging

function Roles.Pump()
  if not Roles.autoInspect or InCombatLockdown() or inspectWindowOpen() then return end
  local now = GetTime()
  if pending then
    if now - pending.at > Roles.INSPECT_TIMEOUT then pending = nil end
    return
  end
  if now - lastInspect < Roles.INSPECT_GAP then return end
  while #queue > 0 do
    local item = table.remove(queue, 1)
    local u = item.unit
    -- the token may point at someone else after a roster change
    if guidOf(u) == item.guid and Plain(Try(CanInspect, u)) then
      pending = { unit = u, guid = item.guid, at = now }
      lastInspect = now
      local ok = pcall(NotifyInspect, u)
      if not ok then pending = nil end
      return
    end
    queued[item.guid] = nil -- try again on the next roster scan
  end
end

local function onInspectReady(_, guid)
  local p = pending
  if not p or Plain(guid) ~= p.guid then return end
  pending = nil
  local ok, buckets = pcall(inspectBuckets)
  local class = classOf(p.unit)
  if ok and buckets and class then
    local role = RoleRules.FromTalents(class, buckets)
    if role then
      cache()[p.guid] = { role = role, t = time() }
      Roles.Changed()
    end
  end
end

-- a re-sort after new role info (debounced)
local changeTimer
function Roles.Changed()
  if changeTimer then return end
  changeTimer = C_Timer.NewTimer and C_Timer.NewTimer(0.5, function()
    changeTimer = nil
    if NF.Party then NF.Party.Apply() end
    if NF.Raid then NF.Raid.Apply() end
  end)
  if not changeTimer then
    if NF.Party then NF.Party.Apply() end
    if NF.Raid then NF.Raid.Apply() end
  end
end

-- Manual override (nil role = back to automatic)
function Roles.SetOverride(name, role)
  if not name then return end
  NF.profile.roleOverrides[name] = role
  Roles.Changed()
end

function Roles.Init()
  -- drop old cache entries
  local now, maxAge = time(), Roles.CACHE_DAYS * 86400
  for guid, c in pairs(cache()) do
    if type(c) ~= "table" or not c.t or now - c.t > maxAge then cache()[guid] = nil end
  end
  NF.On("INSPECT_READY", onInspectReady)
  C_Timer.NewTicker(1, function()
    if #queue > 0 or pending then pcall(Roles.Pump) end
  end)
  local function blocked(_, addon, func)
    if addon == NF.ADDON and type(func) == "string" and func:find("Inspect") then
      Roles.autoInspect = false
      wipe(queue)
      pending = nil
      NF.Print("the client blocked automatic inspecting; roles now come from group roles, raid flags, class and your overrides.")
    end
  end
  NF.On("ADDON_ACTION_BLOCKED", blocked)
  NF.On("ADDON_ACTION_FORBIDDEN", blocked)
end
