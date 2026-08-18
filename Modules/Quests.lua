--[[--------------------------------------------------------------------------
	SlootTracker - Modules/Quests.lua

	Four sources, in descending order of usefulness:

	  1. quests in your log that are ready to hand in  (free completion)
	  2. quests in your log still in progress
	  3. quests offered on the map but not yet accepted (the "undiscovered" ones)
	  4. world quests / bonus objectives currently up

	Honest limitation: the client only knows about quests it is willing to
	offer you. A quest gated behind a prerequisite you have not done, or one
	removed from the game, will not appear here - no addon can list those
	without shipping a static quest database. What you get is every quest you
	could actually walk over and pick up right now, which is the set that
	matters for "clear this zone efficiently".

	The low-level toggle maps to "include trivial quests": quests whose level
	is more than `trivialLevelGap` below yours.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Quests = { key = "quests", label = "Quests", filters = { "quests" } }
ns.Quests = Quests

-- Not registered as a list provider. The client only ever exposes quests it is
-- currently offering, so a quest column could never answer "what is left in
-- this zone" honestly. The module stays loaded because SurveyZone below powers
-- the quest alerts, which only claim what the API can actually see.
-- To put quests back in the list, uncomment the next line.
-- ns:RegisterProvider(Quests)

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local pendingTitles = {}

local function QuestTitle(questID)
	local title = ns.Try(C_QuestLog.GetTitleForQuestID, questID)
	if title and title ~= "" then return title end

	-- Quest text is loaded lazily by the client; ask for it and show a
	-- placeholder until QUEST_DATA_LOAD_RESULT comes back.
	if not pendingTitles[questID] then
		pendingTitles[questID] = true
		ns.Try(C_QuestLog.RequestLoadQuestByID, questID)
	end
	return ("Quest #%d"):format(questID)
end

local function IsTrivial(questID, playerLevel)
	local level = ns.Try(C_QuestLog.GetQuestDifficultyLevel, questID)
	if not level or level <= 0 then return false end
	local gap = ns.db.quests.trivialLevelGap or 10
	return level <= (playerLevel - gap)
end

local function QuestCoords(questID, mapID)
	local x, y = ns.Try(C_QuestLog.GetNextWaypointForMap, questID, mapID)
	if x and y then return x, y end
	return nil
end

-- Which maps do we ask about? GetQuestsOnMap is per-map, so the reach setting
-- decides how many maps we sweep.
local function CandidateMaps(ctx)
	local maps = {}
	local seen = {}

	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			table.insert(maps, id)
		end
	end

	add(ctx.mapID)
	if ns.db.reach == "zone" then return maps end

	local continent = ctx.continentID
	for _, mapID in ipairs(ns.Location.zoneList) do
		local m = ns.Location.maps[mapID]
		if m then
			if ns.db.reach == "world" then
				add(mapID)
			elseif continent and m.continentID == continent then
				add(mapID)
			end
		end
	end
	return maps
end

--------------------------------------------------------------------------
-- 1 + 2: quest log
--------------------------------------------------------------------------

local function ScanQuestLog(out, ctx)
	if not ns.db.quests.includeInLog then return end

	local num = ns.Try(C_QuestLog.GetNumQuestLogEntries) or 0
	for i = 1, num do
		local info = ns.Try(C_QuestLog.GetInfo, i)
		if info and not info.isHeader and info.questID then
			local questID = info.questID
			local mapID = ns.Try(C_TaskQuest.GetQuestZoneID, questID)
			           or ns.Try(GetQuestUiMapID, questID)
			mapID = (mapID and mapID > 0) and mapID or ctx.mapID

			local ready = ns.Try(C_QuestLog.ReadyForTurnIn, questID) or false
			local x, y = QuestCoords(questID, mapID)

			local have, need
			local objectives = ns.Try(C_QuestLog.GetQuestObjectives, questID)
			if type(objectives) == "table" and #objectives > 0 then
				local done = 0
				for _, obj in ipairs(objectives) do
					if obj.finished then done = done + 1 end
				end
				have, need = done, #objectives
			end

			local detail
			if ready then
				detail = "|cff40ff40Ready to turn in|r"
			elseif type(objectives) == "table" then
				local parts = {}
				for _, obj in ipairs(objectives) do
					if not obj.finished and obj.text and obj.text ~= "" then
						table.insert(parts, obj.text)
					end
					if #parts >= 3 then break end
				end
				detail = #parts > 0 and table.concat(parts, ", ") or nil
			end

			table.insert(out, {
				key       = "quest:log:" .. questID,
				module    = "quests",
				category  = "quests",
				id        = questID,
				questID   = questID,
				name      = info.title or QuestTitle(questID),
				icon      = ready and "Interface\\GossipFrame\\ActiveQuestIcon"
				                   or "Interface\\GossipFrame\\AvailableQuestIcon",
				mapID     = mapID,
				x = x, y = y,
				have = have, need = need,
				detail    = detail,
				readyForTurnIn = ready,
				typeLabel = ready and "Turn In" or "In Progress",
				questState = "log",
				link      = ns.Try(GetQuestLink, questID),
			})
		end
	end
end

--------------------------------------------------------------------------
-- 3: quests offered on the map, not yet accepted
--------------------------------------------------------------------------

local function ScanAvailable(out, ctx, maps)
	local includeTrivial = ns.db.quests.includeTrivial
	local seen = {}

	for _, mapID in ipairs(maps) do
		local list = ns.Try(C_QuestLog.GetQuestsOnMap, mapID)
		if type(list) == "table" then
			for _, info in ipairs(list) do
				local questID = info.questID or info.questId
				if questID and not seen[questID] then
					seen[questID] = true

					local onQuest  = ns.Try(C_QuestLog.IsOnQuest, questID)
					local done     = ns.Roster:IsQuestDone(questID)
					local trivial  = IsTrivial(questID, ctx.playerLevel)

					if not onQuest and not done and (includeTrivial or not trivial) then
						local level = ns.Try(C_QuestLog.GetQuestDifficultyLevel, questID)
						local detail = level and level > 0 and ("Level %d"):format(level) or "Available"
						if trivial then detail = detail .. " |cff888888(low level)|r" end

						table.insert(out, {
							key       = "quest:avail:" .. questID,
							module    = "quests",
							category  = "quests",
							id        = questID,
							questID   = questID,
							name      = QuestTitle(questID),
							icon      = "Interface\\GossipFrame\\AvailableQuestIcon",
							mapID     = mapID,
							x = info.x, y = info.y,
							detail    = detail,
							questLevel = level,
							isTrivial = trivial,
							typeLabel = "Available",
							questState = "available",
							link      = ns.Try(GetQuestLink, questID),
						})
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- 4: world quests / bonus objectives
--------------------------------------------------------------------------

local function ScanWorldQuests(out, ctx, maps)
	if not ns.db.quests.includeWorldQuests then return end
	local seen = {}

	for _, mapID in ipairs(maps) do
		local list = ns.Try(C_TaskQuest.GetQuestsForPlayerByMapID, mapID)
		if type(list) == "table" then
			for _, info in ipairs(list) do
				local questID = info.questID or info.questId
				if questID and not seen[questID] then
					seen[questID] = true
					if not ns.Try(C_QuestLog.IsQuestFlaggedCompleted, questID) then
						local timeLeft = ns.Try(C_TaskQuest.GetQuestTimeLeftSeconds, questID)
						local title = ns.Try(C_TaskQuest.GetQuestInfoByQuestID, questID) or QuestTitle(questID)

						local detail = "World Quest"
						if timeLeft and timeLeft > 0 then
							detail = ("World Quest - %s left"):format(SecondsToTime(timeLeft, true))
						end

						table.insert(out, {
							key       = "quest:wq:" .. questID,
							module    = "quests",
							category  = "quests",
							id        = questID,
							questID   = questID,
							name      = title,
							icon      = "Interface\\GossipFrame\\DailyQuestIcon",
							mapID     = info.mapID or mapID,
							x = info.x, y = info.y,
							detail    = detail,
							isWorldQuest = true,
							timeLeft  = timeLeft,
							typeLabel = "World Quest",
							questState = "worldquest",
							link      = ns.Try(GetQuestLink, questID),
						})
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Zone story summary
--------------------------------------------------------------------------

local function ScanZoneStory(out, ctx)
	local achievementID, storyMapID = ns.Try(C_QuestLog.GetZoneStoryInfo, ctx.mapID)
	if not achievementID then return end

	local _, achName, _, completed = ns.Try(GetAchievementInfo, achievementID)
	if completed then return end

	local num = ns.Try(GetAchievementNumCriteria, achievementID) or 0
	if num == 0 then return end

	local done = 0
	local nextChapter
	for i = 1, num do
		local criteriaString, _, criteriaCompleted = ns.Try(GetAchievementCriteriaInfo, achievementID, i)
		if criteriaCompleted then
			done = done + 1
		elseif not nextChapter then
			nextChapter = criteriaString
		end
	end

	table.insert(out, {
		key       = "quest:story:" .. achievementID,
		module    = "quests",
		category  = "quests",
		id        = achievementID,
		name      = achName or "Zone Story",
		icon      = "Interface\\Icons\\INV_Misc_Book_09",
		mapID     = storyMapID or ctx.mapID,
		have      = done,
		need      = num,
		detail    = nextChapter and ("Next chapter: " .. nextChapter)
		            or ("%d of %d chapters complete"):format(done, num),
		typeLabel = "Zone Story",
		questState = "story",
		link      = ns.Try(GetAchievementLink, achievementID),
	})
end

--------------------------------------------------------------------------
-- Zone survey
--
-- A focused, single-map count used by the alert system. Deliberately cheap:
-- one map, no entry construction, no scoring - so it can run on every zone
-- change without waiting for a full scan.
--------------------------------------------------------------------------

function Quests:SurveyZone(mapID, playerLevel)
	local result = {
		mapID = mapID,
		unaccepted = 0, unacceptedTrivial = 0,
		unfinished = 0, unfinishedTrivial = 0,
		readyForTurnIn = 0,
		names = {},
	}
	if not mapID then return result end

	playerLevel = playerLevel or UnitLevel("player")

	local function Remember(name)
		if name and #result.names < 5 then table.insert(result.names, name) end
	end

	-- Offered on the map but not picked up.
	local list = ns.Try(C_QuestLog.GetQuestsOnMap, mapID)
	if type(list) == "table" then
		local seen = {}
		for _, info in ipairs(list) do
			local questID = info.questID or info.questId
			if questID and not seen[questID] then
				seen[questID] = true
				if not ns.Try(C_QuestLog.IsOnQuest, questID) and not ns.Roster:IsQuestDone(questID) then
					local trivial = IsTrivial(questID, playerLevel)
					result.unaccepted = result.unaccepted + 1
					if trivial then result.unacceptedTrivial = result.unacceptedTrivial + 1 end
					Remember(QuestTitle(questID))
				end
			end
		end
	end

	-- Accepted but not handed in, and physically in this zone.
	local num = ns.Try(C_QuestLog.GetNumQuestLogEntries) or 0
	for i = 1, num do
		local info = ns.Try(C_QuestLog.GetInfo, i)
		if info and not info.isHeader and info.questID then
			local questID = info.questID
			local questMap = ns.Try(C_TaskQuest.GetQuestZoneID, questID)
			              or ns.Try(GetQuestUiMapID, questID)

			if questMap == mapID or (questMap == nil and info.isOnMap) then
				local ready = ns.Try(C_QuestLog.ReadyForTurnIn, questID) or false
				local trivial = IsTrivial(questID, playerLevel)

				if ready then
					result.readyForTurnIn = result.readyForTurnIn + 1
				else
					result.unfinished = result.unfinished + 1
					if trivial then result.unfinishedTrivial = result.unfinishedTrivial + 1 end
				end
				Remember(info.title)
			end
		end
	end

	return result
end

--------------------------------------------------------------------------
-- Provider
--------------------------------------------------------------------------

function Quests:Scan(ctx)
	local out = {}
	local maps = CandidateMaps(ctx)

	ns.Try(ScanQuestLog, out, ctx)
	ns.Try(ScanAvailable, out, ctx, maps)
	ns.Try(ScanWorldQuests, out, ctx, maps)
	ns.Try(ScanZoneStory, out, ctx)

	return out
end

--------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------

ns:RegisterEvent("QUEST_DATA_LOAD_RESULT", function(_, questID, success)
	if success and pendingTitles[questID] then
		pendingTitles[questID] = nil
		ns:Fire("ENTRIES_REFRESHED")
	end
end)

local function Bump()
	if ns.db and ns.db.autoRescan then
		C_Timer.After(1.5, function() ns:Fire("REQUEST_SCAN", true) end)
	end
end

ns:RegisterEvent("QUEST_LOG_UPDATE", function()
	if ns.db and ns.db.autoRescan then
		C_Timer.After(3, function() ns:Fire("REQUEST_SCAN") end)
	end
end)
ns:RegisterEvent("QUEST_ACCEPTED", Bump)
ns:RegisterEvent("QUEST_TURNED_IN", Bump)
ns:RegisterEvent("QUEST_REMOVED", Bump)
