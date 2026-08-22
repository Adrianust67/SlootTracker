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

	On broadcasting: sending to a public channel automatically is how people get
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
local nameplates  = {}    -- [unitToken] = readable name, while their plate is up
local lastRosterRequest = 0

--------------------------------------------------------------------------
-- Output channels
--------------------------------------------------------------------------

-- "self" never leaves the client. The rest go through SendChatMessage.
GuildRadar.OUTPUTS = {
	{ key = "self",    label = "Only me (private)" },
	{ key = "GUILD",   label = "Guild chat" },
	{ key = "SAY",     label = "Say" },
	{ key = "CHANNEL", label = "General (zone chat)" },
	{ key = "EMOTE",   label = "Emote" },
}

-- The General channel's number is per-zone and shifts as you travel, so it has
-- to be looked up each time rather than remembered. GetChannelList returns a
-- flat run of values; older clients give id/name pairs and newer ones add a
-- disabled flag, so walk it by type rather than assuming a stride.
local function FindGeneralChannel()
	local list = { ns.Try(GetChannelList) }
	if #list == 0 then return nil end

	local wanted = (type(_G.GENERAL) == "string" and _G.GENERAL or "General"):lower()

	local pendingID
	for _, value in ipairs(list) do
		if type(value) == "number" then
			pendingID = value
		elseif type(value) == "string" and pendingID then
			local name = value:lower()
			if name:find(wanted, 1, true) == 1 then return pendingID, value end
			pendingID = nil
		end
	end
	return nil
end
GuildRadar.FindGeneralChannel = FindGeneralChannel

function GuildRadar:OutputLabel(key)
	for _, def in ipairs(self.OUTPUTS) do
		if def.key == key then return def.label end
	end
	return key or "Only me"
end

--------------------------------------------------------------------------
-- Message building
--------------------------------------------------------------------------

GuildRadar.DEFAULT_TEMPLATE = "%name% is %how% - %count% things to do in %zone%"

-- Substituted generically rather than one gsub per token, so tokens are
-- case-insensitive (%Name% works as well as %name%) and anything unrecognised
-- is left untouched instead of silently vanishing.
local function BuildMessage(template, info)
	local values = {
		name   = info.name or "?",
		zone   = ns.Location:Get().zoneName or "here",
		count  = tostring(#ns.Priority.entries),
		points = tostring(ns.Priority.pointsAvailable or 0),
		how    = info.how == "close" and "right next to you" or "in this zone",
	}

	local text = template or GuildRadar.DEFAULT_TEMPLATE
	text = text:gsub("%%(%a+)%%", function(token)
		return values[token:lower()]   -- nil leaves the original text in place
	end)
	return text
end

-- A message announcing a guildmate that never mentions them is almost always
-- an oversight, so it is worth pointing out once rather than leaving the
-- player wondering why the name never appears.
function GuildRadar:TemplateMentionsName()
	local template = ns.db.guildRadar.template or ""
	return template:lower():find("%%name%%") ~= nil
end

function GuildRadar:ExplainTemplate()
	ns:Print("|cffff8040your message never mentions who was found.|r")
	print("  Add |cffffd100%name%|r where the name should go, for example:")
	print("    |cffffd100/sloot guild msg Hello there %name%, fellow Sloot !!!|r")
	print("  Tokens: |cffffd100%name% %zone% %count% %points% %how%|r")
end

local function Emit(text)
	local output = ns.db.guildRadar.output or "self"

	if output == "self" then
		ns:Print(text)
		return true
	end

	-- Guard the channels that need a valid destination.
	if output == "GUILD" and not IsInGuild() then
		return false
	end

	if output == "CHANNEL" then
		local index, channelName = FindGeneralChannel()
		if not index then
			ns:Print("not in the General channel here - shown privately instead: " .. text)
			return true
		end
		local ok = ns.TryOk(SendChatMessage, text, "CHANNEL", nil, index)
		if not ok then
			ns:Print(("could not post to %s - shown here instead: %s"):format(
				channelName or "General", text))
		end
		return true
	end

	-- TryOk, not Try: SendChatMessage returns nothing, so a nil result means
	-- "returned nothing", not "failed". Testing the return value reported every
	-- successful send as a failure.
	local ok = ns.TryOk(SendChatMessage, text, output)
	if not ok then
		ns:Print(("could not send to %s - shown here instead: %s"):format(output, text))
	end
	return true
end

--------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------

-- The client can hand back "secret" strings that addons are forbidden to
-- inspect - nameplate units are one source. A secret string still reports its
-- type as "string", so a type check does not help; touching it throws. pcall
-- is the only reliable test, and an unreadable name simply means we cannot
-- identify that unit.
local function ShortName(name)
	if type(name) ~= "string" then return nil end

	local ok, short = pcall(string.match, name, "^([^%-]+)")
	if not ok then return nil end
	return short
end

-- Nameplate detection is entirely dependent on friendly player nameplates
-- being switched on, and they are off by default. Without them the game never
-- fires NAME_PLATE_UNIT_ADDED for a guildmate, so "close" mode can never see
-- anyone and silently does nothing.
function GuildRadar:FriendlyNameplatesEnabled()
	local ok = ns.Try(GetCVarBool, "nameplateShowFriends")
	if ok == nil then return true end   -- cannot tell; assume fine
	return ok and true or false
end

function GuildRadar:NameplateModeBlocked()
	local mode = ns.db.guildRadar.mode
	if mode ~= "close" and mode ~= "both" then return false end
	return not self:FriendlyNameplatesEnabled()
end

-- Turning them on is a one-line CVar change, but it is the player's UI, so we
-- ask rather than doing it behind their back.
function GuildRadar:ExplainNameplates()
	ns:Print("|cffff8040nearby detection needs friendly nameplates.|r")
	print("  They are off, so the game never tells the addon a guildmate is in view.")
	print("  Either turn them on:  |cffffd100/console nameplateShowFriends 1|r")
	print("  or switch to zone detection:  |cffffd100/sloot guild mode zone|r")
end

-- Ask the server for a fresh roster, but no more than the game allows.
local function RequestRoster(force)
	if not IsInGuild() then return end
	local now = GetTime()
	if not force and (now - lastRosterRequest) < 11 then return end
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
	for _, name in pairs(nameplates) do
		if name then found[name] = { name = name, how = "close" } end
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

	-- Count what the announcement path actually saw, which is not necessarily
	-- what a separate diagnostic sweep would count - and that gap is exactly
	-- where a bug can hide.
	local foundCount = 0
	for _ in pairs(found) do foundCount = foundCount + 1 end

	-- A forced check is a diagnostic, so report what was actually seen rather
	-- than only the verdict. Guessing at this from the outside has cost us two
	-- rounds already.
	if force then
		local online, sameZone, total = 0, 0, ns.Try(GetNumGuildMembers) or 0
		local myZone = GetRealZoneText()
		local samples = {}

		for i = 1, total do
			local rosterName, _, _, _, _, zone, _, _, isOnline = ns.Try(GetGuildRosterInfo, i)
			if isOnline then
				online = online + 1
				if zone == myZone then
					sameZone = sameZone + 1
					local short = ShortName(rosterName)
					if short and #samples < 4 then table.insert(samples, short) end
				elseif #samples < 4 and zone and online <= 6 then
					table.insert(samples, ("%s |cff888888(%s)|r"):format(
						ShortName(rosterName) or "?", zone or "no zone"))
				end
			end
		end

		local plates = 0
		for _ in pairs(nameplates) do plates = plates + 1 end

		ns.db.lastGuildTest = {
			when = date("%Y-%m-%d %H:%M:%S"),
			mode = cfg.mode, output = cfg.output,
			template = ns.db.guildRadar.template,
			zone = myZone, roster = total, online = online,
			sameZone = sameZone, nameplates = plates,
			found = foundCount, announced = announced,
			nameplateCVar = self:FriendlyNameplatesEnabled(),
			samples = samples,
		}

		ns:Print("guild radar report:")
		print(("  in guild: %s   roster entries: %d   online: %d"):format(
			IsInGuild() and "yes" or "no", total, online))
		print(("  your zone: |cffffd100%s|r"):format(myZone or "?"))
		print(("  guildmates the roster puts in your zone: |cffffd100%d|r"):format(sameZone))
		print(("  guildmates on nameplates right now: |cffffd100%d|r  (friendly nameplates %s)"):format(
			plates, self:FriendlyNameplatesEnabled() and "on" or "|cffff8040OFF|r"))
		print(("  the announcer actually saw: |cffffd100%d|r people, announced |cffffd100%d|r"):format(
			foundCount, announced))
		print(("  mode: |cffffd100%s|r   announcing to: |cffffd100%s|r"):format(
			cfg.mode, self:OutputLabel(cfg.output)))
		print(("  message: %s"):format(ns.db.guildRadar.template or "(none)"))
		if #samples > 0 then
			print("  sample of online guildmates: " .. table.concat(samples, ", "))
		end
		print("  |cff888888Snapshot saved. /reload and the result is on disk.|r")
		if total == 0 then
			print("  |cffff8040The roster is empty - the server has not sent it yet.|r "
				.. "Open the guild frame once, then try again.")
		end
	end

	if force and announced == 0 then
		local n = 0
		for _ in pairs(found) do n = n + 1 end
		if n == 0 then
			-- Say why nothing was found, not just that nothing was found.
			ns:Print(("no guild members detected. Mode |cffffd100%s|r, %d online guild members."):format(
				cfg.mode, ns.Try(GetNumGuildMembers) or 0))
			if self:NameplateModeBlocked() then
				self:ExplainNameplates()
			elseif cfg.mode == "close" then
				print("  Nobody is close enough to have a nameplate up. "
					.. "|cffffd100/sloot guild mode zone|r widens it to the whole zone.")
			end
		else
			ns:Print(("%d guild member(s) nearby, but all announced recently. "
				.. "|cffffd100/sloot guild reset|r clears the cooldowns."):format(n))
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

	-- Token is the key; the readable name is the value.
	nameplates[unit] = name
	local mode = ns.db.guildRadar.mode
	if mode == "close" or mode == "both" then
		GuildRadar:Check(false)
	end
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	-- Keyed by unit token, so removal never has to read a name. Resolving the
	-- name here was both redundant and the thing that crashed: the unit is on
	-- its way out and the client may refuse to let us look at it.
	if unit then nameplates[unit] = nil end
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

ns:On("GUILD_RADAR_CHECK", function(force)
	if force then
		-- Refresh the roster and give the server a moment to answer before
		-- reporting, so a manual test is not judging stale data.
		RequestRoster(true)
		C_Timer.After(1.5, function() GuildRadar:Check(true) end)
		return
	end
	GuildRadar:Check(force)
end)

ns:On("GUILD_RADAR_RESET", function()
	wipe(seenAt)
	lastAnyAt = 0
end)
