--[[--------------------------------------------------------------------------
	SlootTracker - Core/Sources.lua

	"Where do I get this?" for collectibles.

	Blizzard exposes a human-readable source blob for mounts and pets, and
	nothing at all for toys - the toy's origin only exists as tooltip text.
	This file normalises all of that into { mapID, sourceType, sourceText }
	and caches the result, because tooltip parsing is far too slow to redo on
	every scan.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Sources = {}
ns.Sources = Sources

--------------------------------------------------------------------------
-- Source type classification
--------------------------------------------------------------------------

local TYPE_PATTERNS = {
	{ key = "drop",       label = "Drop",       patterns = { "^drop:", "drop:" } },
	{ key = "vendor",     label = "Vendor",     patterns = { "^vendor:", "vendor:" } },
	{ key = "quest",      label = "Quest",      patterns = { "^quest:", "quest:" } },
	{ key = "achievement",label = "Achievement",patterns = { "^achievement:", "achievement:" } },
	{ key = "profession", label = "Profession", patterns = { "^profession:", "profession:" } },
	{ key = "worldevent", label = "World Event",patterns = { "world event", "^event:" } },
	{ key = "treasure",   label = "Treasure",   patterns = { "treasure", "chest" } },
	{ key = "pickpocket", label = "Pickpocket", patterns = { "pick%s?pocket" } },
	{ key = "promotion",  label = "Promotion",  patterns = { "promotion", "trading card", "collector" } },
	{ key = "instore",    label = "Shop",       patterns = { "in%-game shop", "blizzard store" } },
	{ key = "pvp",        label = "PvP",        patterns = { "^pvp", "arena", "battleground", "rated" } },
}

-- Sources we can never route to; hidden when "hide unobtainable" is on.
local UNROUTABLE = {
	promotion = true, instore = true,
}

function Sources:ClassifyText(text)
	if not text or text == "" then return "unknown", "Unknown" end
	local lower = text:lower()
	for _, def in ipairs(TYPE_PATTERNS) do
		for _, pat in ipairs(def.patterns) do
			if lower:find(pat) then return def.key, def.label end
		end
	end
	return "unknown", "Unknown"
end

function Sources:IsRoutable(sourceKey)
	return not UNROUTABLE[sourceKey]
end

-- First meaningful line of the source blob, used as the row's detail text.
function Sources:Headline(text)
	if not text or text == "" then return nil end
	for line in text:gmatch("[^\n\r]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if #line > 0 and not line:lower():find("^zone:") then
			return line
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- Unified resolver
--------------------------------------------------------------------------

-- Returns a table: { mapID, zoneName, sourceKey, sourceLabel, headline, raw }
function Sources:Parse(text)
	local out = {
		raw = text,
		mapID = nil, zoneName = nil,
		sourceKey = "unknown", sourceLabel = "Unknown",
		headline = nil,
	}
	if not text or text == "" then return out end

	out.sourceKey, out.sourceLabel = self:ClassifyText(text)
	out.headline = self:Headline(text)
	out.mapID, out.zoneName = ns.Location:MatchZoneInText(text)
	return out
end

--------------------------------------------------------------------------
-- Tooltip scanning (toys, and anything else with no source API)
--------------------------------------------------------------------------

local function LinesFromTooltipData(data)
	if not data or not data.lines then return nil end

	-- Depending on the client version, tooltip line fields may still be packed
	-- in `args` and need surfacing before leftText exists.
	if TooltipUtil and TooltipUtil.SurfaceArgs then
		ns.Try(TooltipUtil.SurfaceArgs, data)
	end

	local parts = {}
	for _, line in ipairs(data.lines) do
		if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
			ns.Try(TooltipUtil.SurfaceArgs, line)
		end
		local text = line.leftText
		if text and text ~= "" then table.insert(parts, text) end
		if line.rightText and line.rightText ~= "" then table.insert(parts, line.rightText) end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

-- Modern clients expose C_TooltipInfo; fall back to a hidden scanning tooltip
-- on anything older.
local scanner
local function LegacyItemTooltipText(itemID)
	if not scanner then
		scanner = CreateFrame("GameTooltip", "SlootTrackerScanTooltip", nil, "GameTooltipTemplate")
		scanner:SetOwner(UIParent, "ANCHOR_NONE")
	end
	scanner:ClearLines()
	local ok = pcall(scanner.SetItemByID, scanner, itemID)
	if not ok then return nil end

	local parts = {}
	for i = 1, scanner:NumLines() do
		local left = _G["SlootTrackerScanTooltipTextLeft" .. i]
		if left then
			local text = left:GetText()
			if text and text ~= "" then table.insert(parts, text) end
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

function Sources:ItemTooltipText(itemID)
	if not itemID then return nil end
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local data = ns.Try(C_TooltipInfo.GetItemByID, itemID)
		local text = data and LinesFromTooltipData(data)
		if text then return text end
	end
	return LegacyItemTooltipText(itemID)
end

--------------------------------------------------------------------------
-- Persistent cache
--
-- Keyed "kind:id" in the build-stamped cache table, so it resets on patch.
--------------------------------------------------------------------------

local function CacheTable()
	ns.db.cache.sources = ns.db.cache.sources or {}
	return ns.db.cache.sources
end

function Sources:GetCached(kind, id)
	return CacheTable()[kind .. ":" .. id]
end

function Sources:SetCached(kind, id, parsed)
	-- Store only what we need; the raw blob is large and never re-read.
	CacheTable()[kind .. ":" .. id] = {
		m = parsed.mapID,
		z = parsed.zoneName,
		k = parsed.sourceKey,
		h = parsed.headline,
	}
end

function Sources:Resolve(kind, id, textProvider)
	local cached = self:GetCached(kind, id)
	if cached then
		return {
			mapID = cached.m, zoneName = cached.z,
			sourceKey = cached.k or "unknown",
			sourceLabel = cached.k and cached.k:gsub("^%l", string.upper) or "Unknown",
			headline = cached.h,
		}
	end

	local text = textProvider and textProvider()
	local parsed = self:Parse(text)
	self:SetCached(kind, id, parsed)
	return parsed
end

function Sources:ClearCache()
	ns.db.cache.sources = {}
end
