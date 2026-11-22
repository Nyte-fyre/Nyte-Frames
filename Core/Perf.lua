-- Perf.lua: opt-in profiler for the 25-man performance pass (/nf perf).
--
-- While running, every Nyte event handler is timed with debugprofilestop()
-- and counted per event. When the window ends the totals are printed and
-- saved to NyteFramesProbeDB.perf so they can be read outside the game.
-- Off by default: the only cost when off is one boolean check per event.
local _, NF = ...
local Perf = {}
NF.Perf = Perf

Perf.on = false
local stats, startedAt, startMem, peakMs, ticker = {}, 0, 0, 0, nil

local function now()
  if debugprofilestop then return debugprofilestop() end
  if GetTimePreciseSec then return GetTimePreciseSec() * 1000 end
  return 0
end
Perf.Now = now

-- Record one handler run (milliseconds).
function Perf.Add(name, ms)
  local s = stats[name]
  if not s then
    s = { n = 0, ms = 0, max = 0 }
    stats[name] = s
  end
  s.n = s.n + 1
  s.ms = s.ms + ms
  if ms > s.max then s.max = ms end
  if ms > peakMs then peakMs = ms end
end

local function memoryKB()
  local update = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
  local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
  if not (update and get) then return nil end
  pcall(update)
  local ok, kb = pcall(get, NF.ADDON)
  return ok and kb or nil
end

local function context()
  local inInstance, kind = false, "none"
  if IsInInstance then
    local ok, a, b = pcall(IsInInstance)
    if ok then inInstance, kind = a, b end
  end
  local members = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  return string.format("%s, %d in group", inInstance and tostring(kind) or "world", members)
end

function Perf.Start(seconds)
  seconds = math.max(10, math.min(600, tonumber(seconds) or 60))
  stats, peakMs = {}, 0
  startedAt = (GetTime and GetTime()) or 0
  startMem = memoryKB() or 0
  Perf.on = true
  Perf.seconds = seconds
  if ticker then ticker:Cancel() end
  ticker = C_Timer.NewTicker(seconds, function()
    if ticker then ticker:Cancel() ticker = nil end
    Perf.Stop()
  end)
  NF.Print(string.format("profiling for %ds (%s). Play normally; results print when it ends (/nf perf stop to end early).", seconds, context()))
end

function Perf.Report()
  local elapsed = math.max(0.001, ((GetTime and GetTime()) or 0) - startedAt)
  local rows, totalMs, totalN = {}, 0, 0
  for name, s in pairs(stats) do
    rows[#rows + 1] = { name = name, n = s.n, ms = s.ms, max = s.max }
    totalMs, totalN = totalMs + s.ms, totalN + s.n
  end
  table.sort(rows, function(a, b) return a.ms > b.ms end)
  local mem = memoryKB()
  return {
    seconds = elapsed, context = context(), totalMs = totalMs, calls = totalN,
    msPerSec = totalMs / elapsed, peakMs = peakMs, memKB = mem, memStartKB = startMem,
    rows = rows, version = NF.VERSION,
  }
end

function Perf.Stop()
  if not Perf.on then NF.Print("the profiler isn't running. /nf perf [seconds] starts it.") return end
  Perf.on = false
  if ticker then ticker:Cancel() ticker = nil end
  local r = Perf.Report()
  NF.Print(string.format("%.0fs in %s: %d handler runs, %.1f ms total = %.2f ms per second (%.2f%% of one core), slowest single run %.2f ms.",
    r.seconds, r.context, r.calls, r.totalMs, r.msPerSec, r.msPerSec / 10, r.peakMs))
  if r.memKB then print(string.format("  memory %.0f KB (started at %.0f KB)", r.memKB, r.memStartKB)) end
  for i = 1, math.min(8, #r.rows) do
    local x = r.rows[i]
    print(string.format("  %-34s %6d runs  %7.2f ms  avg %.3f  max %.2f", x.name, x.n, x.ms, x.ms / x.n, x.max))
  end
  -- keep it for offline reading (plain numbers/strings only)
  if type(NyteFramesProbeDB) == "table" then
    NyteFramesProbeDB.perf = NyteFramesProbeDB.perf or {}
    local list = NyteFramesProbeDB.perf
    local top = {}
    for i = 1, math.min(25, #r.rows) do top[i] = r.rows[i] end
    r.rows = top
    r.at = (date and date("%Y-%m-%d %H:%M")) or "?"
    table.insert(list, 1, r)
    while #list > 10 do table.remove(list) end
  end
  print("  saved; /reload to write it to disk.")
end

function Perf.Command(rest)
  rest = (rest or ""):lower()
  if rest == "stop" then Perf.Stop() return end
  Perf.Start(tonumber(rest))
end
