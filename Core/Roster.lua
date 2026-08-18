--[[--------------------------------------------------------------------------
	SlootTracker - Core/Roster.lua

	The scope selector needs data the game will not give us.

	Account-wide already, straight from the API:
	  mounts, toys, battle pets, transmog, heirlooms, most achievements.
	Per-character, and only readable while you are logged into that character:
	  quest completion, exploration, character-earned achievement credit.

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

local function Me()
	if not ns.playerKey then return nil end
	local db = ns.db.roster
	local rec = db[ns.playerKey]
	if not rec then
		rec = { quests = {}, explored = {} }
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
-- Completed quests
--
-- GetAllCompletedQuestIDs returns a large array (tens of thousands on an old
-- character). It is stored sorted so the saved-variables file compresses well
-- and so lookups can be built into a hash on demand.
--------------------------------------------------------------------------

local questLookupCache = {}   -- [characterKey] = { [questID] = true }
local accountQuestCache = nil

function Roster:CaptureQuests()
	if not ns.db.quests.storeCompleted then return end
	local rec = Me()
	if not rec then return end

	local ids = ns.Try(C_QuestLog.GetAllCompletedQuestIDs)
	if type(ids) ~= "table" or #ids == 0 then return end

	table.sort(ids)
	rec.quests = ids
	rec.questCount = #ids
	rec.questsCapturedAt = time()

	questLookupCache[ns.playerKey] = nil
	accountQuestCache = nil
	ns:Debug(("captured %d completed quests"):format(#ids))
end

local function LookupFor(key)
	local cache = questLookupCache[key]
	if cache then return cache end

	local rec = ns.db.roster[key]
	if not rec or type(rec.quests) ~= "table" then return nil end

	cache = {}
	for i = 1, #rec.quests do cache[rec.quests[i]] = true end
	questLookupCache[key] = cache
	return cache
end

-- Has THIS character completed the quest? Always trust the live API first.
function Roster:HasCharacterCompletedQuest(questID)
	local live = ns.Try(C_QuestLog.IsQuestFlaggedCompleted, questID)
	if live ~= nil then return live end
	local cache = LookupFor(ns.playerKey)
	return cache and cache[questID] or false
end

-- Has ANY recorded character completed it?
function Roster:HasAccountCompletedQuest(questID)
	if self:HasCharacterCompletedQuest(questID) then return true end

	if not accountQuestCache then
		accountQuestCache = {}
		for key in pairs(ns.db.roster) do
			if key ~= ns.playerKey then
				local cache = LookupFor(key)
				if cache then
					for id in pairs(cache) do accountQuestCache[id] = true end
				end
			end
		end
	end
	return accountQuestCache[questID] or false
end

function Roster:IsQuestDone(questID)
	if ns:IsAccountScope("quests") then
		return self:HasAccountCompletedQuest(questID)
	end
	return self:HasCharacterCompletedQuest(questID)
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
			questCount = rec.questCount or (type(rec.quests) == "table" and #rec.quests) or 0,
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
	questLookupCache[key] = nil
	accountQuestCache = nil
end

--------------------------------------------------------------------------
-- Scope helper used everywhere else
--------------------------------------------------------------------------

-- Quest completion is the only thing that genuinely needs the roster, so
-- "thin data" means: we are answering quest questions account-wide while
-- knowing about a single character. The UI warns instead of quietly showing
-- character data under an account-wide label.
function Roster:AccountDataIsThin()
	return ns:IsAccountScope("quests") and self:CharacterCount() <= 1
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	Roster:UpdateIdentity()
	C_Timer.After(6, function() Roster:CaptureQuests() end)
end)

ns:RegisterEvent("PLAYER_LEVEL_UP", function() Roster:UpdateIdentity() end)
ns:RegisterEvent("PLAYER_LOGOUT", function()
	Roster:UpdateIdentity()
	Roster:CaptureQuests()
end)

-- Keep the stored set fresh without re-pulling 20k ids constantly.
local dirty = false
ns:RegisterEvent("QUEST_TURNED_IN", function()
	if dirty then return end
	dirty = true
	C_Timer.After(20, function()
		dirty = false
		Roster:CaptureQuests()
	end)
end)
