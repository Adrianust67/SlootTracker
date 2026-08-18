--[[--------------------------------------------------------------------------
	SlootTracker - Core/Roster.lua

	The scope selector needs data the game will not give us.

	Account-wide already, straight from the API:
	  mounts, toys, battle pets, transmog, heirlooms, most achievements.
	Per-character, and only readable while you are logged into that character:
	  exploration, and which character earned a given achievement.

	So the roster records what each character has done as you play it, and
	"account" scope answers questions by folding every recorded character
	together. A character you have never logged into since installing simply
	does not contribute - the UI says so rather than pretending otherwise.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Roster = {}
ns.Roster = Roster

--------------------------------------------------------------------------
-- Per-character record
--------------------------------------------------------------------------

-- One-time cleanup: earlier versions stored every completed quest id per
-- character, which ran to tens of thousands of numbers and made the saved
-- variables file enormous. Nothing reads them any more, so drop them.
local function PurgeLegacyQuestData()
	local freed = 0
	for _, rec in pairs(ns.db.roster or {}) do
		if rec.quests then
			freed = freed + (type(rec.quests) == "table" and #rec.quests or 0)
			rec.quests = nil
		end
		rec.questCount = nil
		rec.questsCapturedAt = nil
	end
	if freed > 0 then
		ns:Debug(("dropped %d stored quest ids"):format(freed))
	end
end

local function Me()
	if not ns.playerKey then return nil end
	local db = ns.db.roster
	local rec = db[ns.playerKey]
	if not rec then
		rec = { explored = {} }
		db[ns.playerKey] = rec
	end
	return rec
end
Roster.Me = Me

function Roster:UpdateIdentity()
	local rec = Me()
	if not rec then return end

	local _, class = UnitClass("player")
	rec.name    = ns.playerName
	rec.realm   = ns.playerRealm
	rec.class   = class
	rec.level   = UnitLevel("player")
	rec.faction = UnitFactionGroup("player")
	rec.race    = select(2, UnitRace("player"))
	rec.lastSeen = time()
	rec.mapID   = ns.Location and ns.Location.current.mapID or nil
	rec.points  = GetTotalAchievementPoints and GetTotalAchievementPoints() or nil
end

--------------------------------------------------------------------------
-- Explored areas (for account-wide exploration)
--------------------------------------------------------------------------

-- rec.explored[uiMapID] = { [criteriaIndex] = true }  -- completed criteria
function Roster:RecordExplored(mapID, completedIndices)
	local rec = Me()
	if not rec then return end
	rec.explored = rec.explored or {}
	rec.explored[mapID] = completedIndices
end

function Roster:IsAreaExploredByAnyone(mapID, criteriaIndex)
	for _, rec in pairs(ns.db.roster) do
		local m = rec.explored and rec.explored[mapID]
		if m and m[criteriaIndex] then return true end
	end
	return false
end

--------------------------------------------------------------------------
-- Roster queries for the UI
--------------------------------------------------------------------------

function Roster:GetCharacters()
	local list = {}
	for key, rec in pairs(ns.db.roster) do
		table.insert(list, {
			key      = key,
			name     = rec.name or key,
			realm    = rec.realm,
			class    = rec.class,
			level    = rec.level,
			faction  = rec.faction,
			lastSeen = rec.lastSeen or 0,
			isMe     = (key == ns.playerKey),
		})
	end
	table.sort(list, function(a, b)
		if a.isMe ~= b.isMe then return a.isMe end
		return (a.lastSeen or 0) > (b.lastSeen or 0)
	end)
	return list
end

function Roster:CharacterCount()
	local n = 0
	for _ in pairs(ns.db.roster) do n = n + 1 end
	return n
end

function Roster:Forget(key)
	ns.db.roster[key] = nil
end

--------------------------------------------------------------------------
-- Scope helper used everywhere else
--------------------------------------------------------------------------

-- Exploration is the only per-character thing the roster still answers, so a
-- single recorded character only misleads when exploration is account-scoped.
function Roster:AccountDataIsThin()
	return ns:IsAccountScope("exploration") and self:CharacterCount() <= 1
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	PurgeLegacyQuestData()
	Roster:UpdateIdentity()
end)

ns:RegisterEvent("PLAYER_LEVEL_UP", function() Roster:UpdateIdentity() end)
ns:RegisterEvent("PLAYER_LOGOUT", function()
	Roster:UpdateIdentity()
end)
