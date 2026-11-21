-- Media.lua: LibSharedMedia registration and lookups.
local _, NF = ...
local Media = {}
NF.Media = Media

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
Media.LSM = LSM

Media.FLAT = "Interface\\Buttons\\WHITE8X8"

function Media.Init()
  if LSM then
    LSM:Register("statusbar", "Nyte Flat", Media.FLAT)
    LSM:Register("background", "Nyte Flat", Media.FLAT)
  end
end

function Media.Texture(name)
  return (LSM and name and LSM:Fetch("statusbar", name, true)) or Media.FLAT
end

function Media.Font(name)
  return (LSM and name and LSM:Fetch("font", name, true)) or STANDARD_TEXT_FONT
end
