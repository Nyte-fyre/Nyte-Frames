-- Roles.lua: resolve TANK / HEALER / DAMAGER for a group member.
--
-- Chain (handoff section 5), first answer wins:
--   1. manual override (profile.roleOverrides, by character name)
--   2. UnitGroupRolesAssigned, TANK/HEALER only: this client reports DAMAGER
--      for anyone without a role set (probe #1), so DAMAGER isn't trusted.
--      Exception: the group role doesn't follow a spec swap on this client
--      (a tank who swaps to DPS stays TANK), so a talent inspect made after
--      the last role change, triggered by PLAYER_SPECIALIZATION_CHANGED, wins.
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
local assignedSeen = {}     -- [guid] = { role, seq, name }: when the group role last changed
local picks = {}            -- [name] = { role, seq }: a role someone picked this session
local swapping = {}         -- [guid] = true: re-inspect after a spec swap is pending
local refreshed = {}        -- [guid] = true: an old cached result was re-checked this session
local seq = 0               -- session order of role picks vs. inspects
local function nextSeq() seq = seq + 1 return seq end

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
  local guid = guidOf(unit)
  local c = guid and NyteFramesDB and cache()[guid]
  -- a role picked in the role menu this session (Damage included: then the
  -- game's DAMAGER is a real answer, not "nothing set"), unless talents were
  -- read after it
  local pick = name and picks[name]
  if pick and pick.role == assigned and not (c and c.seq and c.seq > pick.seq) then
    return assigned, "picked"
  end
  if assigned == "TANK" or assigned == "HEALER" then
    local seen = guid and assignedSeen[guid]
    if guid and (not seen or seen.role ~= assigned) then
      seen = { role = assigned, seq = nextSeq(), name = name }
      assignedSeen[guid] = seen
    end
    -- talents read after the role was picked (a spec swap) beat the stale role
    if c and c.role and c.afterSwap and c.seq and seen and c.seq > seen.seq then return c.role, "talents" end
    return assigned, "assigned"
  end
  if roster[unit] and roster[unit].mainTank then return "TANK", "roster" end
  if c and c.role then
    -- a result from an earlier session may be out of date (respec): check once
    if not c.seq and not refreshed[guid] and Roles.autoInspect then
      refreshed[guid] = true
      queued[guid] = nil
      Roles.Queue(unit)
    end
    return c.role, "talents"
  end
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
  queued[p.guid] = nil -- done: a later spec swap / refresh may queue it again
  local ok, buckets = pcall(inspectBuckets)
  local class = classOf(p.unit)
  if ok and buckets and class then
    local role = RoleRules.FromTalents(class, buckets)
    if role then
      -- seq: read this session, so it can outrank an older role pick
      cache()[p.guid] = { role = role, t = time(), seq = nextSeq(), afterSwap = swapping[p.guid] }
      swapping[p.guid] = nil
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

-- A group member swapped spec: forget their talents and inspect again.
function Roles.SpecChanged(unit)
  unit = Plain(unit)
  if type(unit) ~= "string" or not (unit:find("^party%d") or unit:find("^raid%d")) then return end
  local guid = guidOf(unit)
  if not guid then return end
  if NyteFramesDB then cache()[guid] = nil end
  swapping[guid] = true
  queued[guid] = nil
  Roles.Queue(unit)
  Roles.Changed()
end

-- /nf role refresh: forget every group member's talents and inspect again.
function Roles.RefreshAll()
  local n = 0
  local prefix, count = "party", 4
  if IsInRaid() then prefix, count = "raid", 40 end
  for i = 1, count do
    local u = prefix .. i
    local guid = guidOf(u)
    if guid then
      if NyteFramesDB then cache()[guid] = nil end
      swapping[guid] = true -- treat like a spec swap: the result can beat a stale role
      queued[guid] = nil
      Roles.Queue(u)
      n = n + 1
    end
  end
  Roles.Changed()
  return n
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
    if type(c) ~= "table" or not c.t or now - c.t > maxAge then cache()[guid] = nil
    else c.seq, c.afterSwap = nil, nil end -- last session's inspect doesn't outrank this session's roles
  end
  NF.On("INSPECT_READY", onInspectReady)
  NF.On("PLAYER_SPECIALIZATION_CHANGED", function(_, unit) Roles.SpecChanged(unit) end)
  -- a role picked again (even the same one) outranks older talents
  NF.On("ROLE_CHANGED_INFORM", function(_, changed, _, _, newRole)
    changed = Plain(changed)
    if type(changed) ~= "string" then return end
    changed = changed:gsub("%-.*$", "")
    newRole = Plain(newRole)
    if newRole == "TANK" or newRole == "HEALER" or newRole == "DAMAGER" then
      picks[changed] = { role = newRole, seq = nextSeq() }
    else
      picks[changed] = nil
    end
    for guid, seen in pairs(assignedSeen) do
      if seen.name == changed then assignedSeen[guid] = nil end
    end
    Roles.Changed()
  end)
  C_Timer.NewTicker(1, function()
    if #queue > 0 or pending then pcall(Roles.Pump) end
  end)
  local function blocked(_, addon, func)
    if addon == NF.ADDON and type(func) == "string" and func:find("Inspect") then
      Roles.autoInspect = false
      wipe(queue)
      pending = nil
      NF.Print(NF.L["the client blocked automatic inspecting; roles now come from group roles, raid flags, class and your overrides."])
    end
  end
  NF.On("ADDON_ACTION_BLOCKED", blocked)
  NF.On("ADDON_ACTION_FORBIDDEN", blocked)
end
