-- Locale.lua: translation table. Every user-facing string goes through
-- L["English text"]; a missing translation falls back to the English key, so
-- the addon always works in English and a locale file can be partial.
--
-- A translation file (Locales\deDE.lua etc., listed in the TOC after this one):
--   local _, NF = ...
--   local L = NF.NewLocale("deDE")
--   if not L then return end
--   L["Player"] = "Spieler"
--
-- Strings with %s / %d are format strings: keep the placeholders in the
-- translation, in the same order. `python tools/locale_keys.py` rebuilds
-- Locales\_template.lua with every key in the code.
local _, NF = ...

local L = setmetatable({}, { __index = function(_, k) return k end })
NF.L = L
NF.LOCALE = (GetLocale and GetLocale()) or "enUS"

-- The table to fill when the client runs `code`, else nil (skip the file).
function NF.NewLocale(code)
  if code ~= NF.LOCALE or code == "enUS" or code == "enGB" then return nil end
  return L
end
