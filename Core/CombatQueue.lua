-- CombatQueue.lua: run secure-frame work only out of combat.
-- NF.RunOOC(key, fn) runs fn now, or once after combat if we're locked down.
-- A later call with the same key replaces the queued one (last write wins).
local _, NF = ...

local queue, order = {}, {}

function NF.RunOOC(key, fn)
  if not InCombatLockdown() then
    local ok, err = pcall(fn)
    if not ok then NF.Error("RunOOC " .. tostring(key), err) end
    return true
  end
  if not queue[key] then order[#order + 1] = key end
  queue[key] = fn
  return false
end

NF.On("PLAYER_REGEN_ENABLED", function()
  local keys = order
  order = {}
  for _, key in ipairs(keys) do
    local fn = queue[key]
    queue[key] = nil
    if fn then
      local ok, err = pcall(fn)
      if not ok then NF.Error("RunOOC " .. tostring(key), err) end
    end
  end
end)
