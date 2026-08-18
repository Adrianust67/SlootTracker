--[[--------------------------------------------------------------------------
	Sloot Tracker - Modules/GuildRadar.lua

	Spots guild members near you and announces it.

	Two detection methods, because the API gives you a choice between broad
	and precise:

	  "zone"  - the guild roster reports each online member's current zone, so
	            we compare that against yours. Catches everyone in the zone,
	            but "zone" is as fine-grained as it gets.
	  "close" - nameplate units. NAME_PLATE_UNIT_ADDED fires for players who
	            come into nameplate range (roughly 40-60 yards), and
	            UnitIsInMyGuild tells us if they are ours. Genuinely close by,
	            but only catches people you can actually see.
	  "both"  - run both; the closer detection wins for a given player.

	On broadcasting: sending to GUILD/SAY/YELL automatically is how people get
	muted and reported, so the default output is your own chat frame and
	nothing leaves your client. Broadcasting is opt-in, rate limited globally
	and per player, and never fires twice for the same person inside the
	cooldown.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local GuildRadar = {}
ns.GuildRadar = GuildRadar

local seenAt      = {}    -- [playerName] = GetTime() of last announcement
local lastAnyAt   = 0     -- global rate limit
local nameplates  = {}    -- [playerName] = true while their nameplate is up
local lastRosterRequest = 0

--------------------------------------------------------------------------
-- Output channels
--------------------------------------------------------------------------

-- "self" never leaves the client. The rest go through SendChatMessage.
GuildRadar.OUTPUTS = {
	{ key = "self",  label = "Only me (private)" },
	{ key = "GUILD", label = "Guild chat" },
	{ key = "SAY",   label = "Say" },
	{ key = "YELL",  label = "Yell" },
	{ key = "PARTY", label = "Party" },
	{ key = "EMOTE", label = "Emote" },
}

function GuildRadar:OutputLabel(key)
	for _, def in ipairs(self.OUTPUTS) do
		if def.key == key then return def.label end
	end
	return key or "Only me"
end

--------------------------------------------------------------------------
-- Message building
--------------------------------------------------------------------------

-- Tokens the template understands.
local function BuildMessage(template, info)
	local zone = ns.Location:Get().zoneName or "here"
	local count = #ns.Priority.entries
	local points = ns.Priority.pointsAvailable or 0

	local text = template or "%name% is nearby in %zone%"
	text = text:gsub("%%name%%",   info.name or "?")
	text = text:gsub("%%zone%%",   zone)
	text = text:gsub("%%count%%",  tostring(count))
	text = text:gsub("%%points%%", tostring(points))
	text = text:gsub("%%how%%",    info.how == "close" and "right next to you" or "in this zone")
	return text
end

local function Emit(text)
	local output = ns.db.guildRadar.output or "self"

	if output == "self" then
		ns:Print(text)
		return true
	end

	-- Guard the channels that need a valid destination.
	if output == "PARTY" and not IsInGroup() then
		ns:Print(text .. " |cff888888(not in a party, shown privately)|r")
		return true
	end
	if output == "GUILD" and not IsInGuild() then
		return false
	end

	local ok = ns.Try(SendChatMessage, text, output)
	if ok == nil then
		-- SendChatMessage failed or was blocked; never silently swallow it.
		ns:Print(text .. " |cff888888(could not send to " .. output .. ")|r")
	end
	return true
end

--------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------

local function ShortName(name)
	if not name then return nil end
	return (name:match("^([^%-]+)")) or name
end

-- Ask the server for a fresh roster, but no more than the game allows.
local function RequestRoster()
	if not IsInGuild() then return end
	local now = GetTime()
	if (now - lastRosterRequest) < 11 then return end
	lastRosterRequest = now

	if C_GuildInfo and C_GuildInfo.GuildRoster then
		ns.Try(C_GuildInfo.GuildRoster)
	elseif GuildRoster then
		ns.Try(GuildRoster)
	end
end

-- Guild members whose roster zone matches ours.
local function ScanRosterForZone(found)
	if not IsInGuild() then return end

	local myZone = GetRealZoneText()
	if not myZone or myZone == "" then return end

	local myName = ns.playerName
	local total = ns.Try(GetNumGuildMembers) or 0

	for i = 1, total do
		local name, _, _, level, _, zone, _, _, isOnline, _, class = ns.Try(GetGuildRosterInfo, i)
		local short = ShortName(name)
		if isOnline and short and short ~= myName and zone == myZone then
			found[short] = found[short] or { name = short, how = "zone", level = level, class = class }
		end
	end
end

-- Guild members currently rendering a nameplate, i.e. actually close.
local function ScanNameplates(found)
	for name in pairs(nameplates) do
		found[name] = { name = name, how = "close" }
	end
end

--------------------------------------------------------------------------
-- Announce
--------------------------------------------------------------------------

function GuildRadar:Check(force)
	local cfg = ns.db.guildRadar
	if not cfg.enabled and not force then return end
	if not IsInGuild() then
		if force then ns:Print("you are not in a guild.") end
		return
	end

	local now = GetTime()
	if not force and (now - lastAnyAt) < (cfg.minInterval or 20) then return end

	local found = {}
	if cfg.mode == "zone" or cfg.mode == "both" then RequestRoster(); ScanRosterForZone(found) end
	if cfg.mode == "close" or cfg.mode == "both" then ScanNameplates(found) end

	local announced = 0
	for name, info in pairs(found) do
		local last = seenAt[name]
		if force or not last or (now - last) >= (cfg.cooldown or 600) then
			seenAt[name] = now
			if Emit(BuildMessage(cfg.template, info)) then
				announced = announced + 1
				lastAnyAt = now
			end
			-- One player per check keeps a busy hub from turning into a wall
			-- of text, and keeps us well clear of the chat throttle.
			break
		end
	end

	if cfg.sound and announced > 0 then
		ns.Try(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081, "Master")
	end

	if force and announced == 0 then
		local n = 0
		for _ in pairs(found) do n = n + 1 end
		if n == 0 then
			ns:Print("no guild members detected nearby.")
		else
			ns:Print(("%d guild member(s) nearby, but all announced recently."):format(n))
		end
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	if not (ns.db and ns.db.guildRadar.enabled) then return end
	if not unit or not UnitIsPlayer(unit) then return end
	if not ns.Try(UnitIsInMyGuild, unit) then return end

	local name = ShortName(UnitName(unit))
	if not name or name == ns.playerName then return end

	nameplates[name] = true
	local mode = ns.db.guildRadar.mode
	if mode == "close" or mode == "both" then
		GuildRadar:Check(false)
	end
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	if not unit then return end
	local name = ShortName(UnitName(unit))
	if name then nameplates[name] = nil end
end)

ns:On("ZONE_CHANGED", function()
	if not (ns.db and ns.db.guildRadar.enabled) then return end
	wipe(nameplates)
	if ns.db.guildRadar.mode == "zone" or ns.db.guildRadar.mode == "both" then
		C_Timer.After(5, function() GuildRadar:Check(false) end)
	end
end)

ns:RegisterEvent("GUILD_ROSTER_UPDATE", function()
	if not (ns.db and ns.db.guildRadar.enabled) then return end
	local mode = ns.db.guildRadar.mode
	if mode == "zone" or mode == "both" then GuildRadar:Check(false) end
end)

ns:On("GUILD_RADAR_CHECK", function(force) GuildRadar:Check(force) end)

ns:On("GUILD_RADAR_RESET", function()
	wipe(seenAt)
	lastAnyAt = 0
end)
