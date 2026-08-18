--[[--------------------------------------------------------------------------
	ZoneComplete - Modules/Collections.lua

	Uncollected mounts, toys, battle pets, transmog sets, heirlooms and titles.

	Collections are account-wide by design, so the scope selector changes only
	one thing here: character scope hides things this character cannot use or
	obtain (wrong faction, wrong class), account scope shows everything the
	account is still missing.

	Enumerating the Toy Box requires temporarily widening its filters, which is
	the player's UI state - so that happens exactly once per client build, the
	previous filter state is restored immediately, and the resulting item list
	is cached.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Collections = {}
ns.Collections = Collections

local FACTION_HORDE, FACTION_ALLIANCE = 0, 1

--------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------

local function ZoneGate(entry, parsed)
	-- requireZoneMatch hides collectibles we could not tie to a place, which
	-- is the sane default for a location-driven list.
	if parsed.mapID then return true end
	return not ns.db.collections.requireZoneMatch and ns.db.reach == "world"
end

local function ApplyParsed(entry, parsed)
	entry.mapID     = parsed.mapID
	entry.zoneName  = parsed.zoneName
	entry.sourceKey = parsed.sourceKey
	entry.detail    = parsed.headline or parsed.sourceLabel
	if parsed.zoneName and parsed.headline then
		entry.detail = ("%s - %s"):format(parsed.sourceLabel, parsed.headline)
	end
	return entry
end

--------------------------------------------------------------------------
-- Mounts
--------------------------------------------------------------------------

local function ScanMounts(out, ctx)
	local ids = ns.Try(C_MountJournal.GetMountIDs)
	if type(ids) ~= "table" then return end

	-- Collections are account-wide, full stop - there is no per-character
	-- notion of owning a mount. The only per-character question is whether
	-- THIS character could go and get it, which is its own setting.
	local hideUnusable = ns.db.collections.hideUnusable

	for _, mountID in ipairs(ids) do
		local name, spellID, icon, _, _, sourceType, _, isFactionSpecific, faction,
		      shouldHideOnChar, isCollected = ns.Try(C_MountJournal.GetMountInfoByID, mountID)

		if name and not isCollected then
			local usable = true
			if hideUnusable then
				if shouldHideOnChar then usable = false end
				if isFactionSpecific and faction ~= nil then
					local mine = (ns.playerFaction == "Horde") and FACTION_HORDE or FACTION_ALLIANCE
					if faction ~= mine then usable = false end
				end
			end

			if usable then
				local parsed = ns.Sources:Resolve("mount", mountID, function()
					local _, _, source = ns.Try(C_MountJournal.GetMountInfoExtraByID, mountID)
					return source
				end)

				if ns.db.collections.hideUnobtainable and not ns.Sources:IsRoutable(parsed.sourceKey) then
					-- skip promotions / store mounts
				else
					local entry = {
						key       = "mount:" .. mountID,
						module    = "collections",
						category  = "mounts",
						id        = mountID,
						spellID   = spellID,
						name      = name,
						icon      = icon,
						typeLabel = "Mount",
						link      = spellID and ("|cff71d5ff|Hspell:%d|h[%s]|h|r"):format(spellID, name) or nil,
					}
					ApplyParsed(entry, parsed)
					if ZoneGate(entry, parsed) then table.insert(out, entry) end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Toys
--
-- The Toy Box has no "give me every toy" call - GetToyFromIndex walks the
-- FILTERED list. So: snapshot the filters, open them all the way up, harvest
-- the item ids, put the filters back. Cached, so this happens once.
--------------------------------------------------------------------------

local function ToyCache()
	ns.db.cache.toys = ns.db.cache.toys or {}
	return ns.db.cache.toys
end

local function HarvestToyIDs()
	local cache = ToyCache()
	if cache.ids then return cache.ids end

	-- Do not stomp the player's filters while they are looking at them.
	if _G.ToyBox and _G.ToyBox:IsShown() then return nil end

	local saved = {
		collected   = ns.Try(C_ToyBox.GetCollectedShown),
		uncollected = ns.Try(C_ToyBox.GetUncollectedShown),
		search      = _G.ToyBox and _G.ToyBox.searchString or nil,
		sources     = {},
		expansions  = {},
	}
	for i = 1, 20 do
		local checked = ns.Try(C_ToyBox.IsSourceTypeFilterChecked, i)
		if checked == nil then break end
		saved.sources[i] = checked
	end
	for i = 1, 20 do
		local checked = ns.Try(C_ToyBox.IsExpansionTypeFilterChecked, i)
		if checked == nil then break end
		saved.expansions[i] = checked
	end

	ns.Try(C_ToyBox.SetCollectedShown, true)
	ns.Try(C_ToyBox.SetUncollectedShown, true)
	ns.Try(C_ToyBox.SetAllSourceFilters, true)
	ns.Try(C_ToyBox.SetAllExpansionTypeFilters, true)
	ns.Try(C_ToyBox.SetFilterString, "")

	local ids = {}
	local total = ns.Try(C_ToyBox.GetNumFilteredToys) or 0
	for i = 1, total do
		local itemID = ns.Try(C_ToyBox.GetToyFromIndex, i)
		if itemID and itemID > 0 then table.insert(ids, itemID) end
	end

	-- Restore.
	if saved.collected ~= nil then ns.Try(C_ToyBox.SetCollectedShown, saved.collected) end
	if saved.uncollected ~= nil then ns.Try(C_ToyBox.SetUncollectedShown, saved.uncollected) end
	for i, checked in pairs(saved.sources) do
		ns.Try(C_ToyBox.SetSourceTypeFilter, i, checked)
	end
	for i, checked in pairs(saved.expansions) do
		ns.Try(C_ToyBox.SetExpansionTypeFilter, i, checked)
	end
	if saved.search and saved.search ~= "" then ns.Try(C_ToyBox.SetFilterString, saved.search) end

	if #ids > 0 then
		cache.ids = ids
		ns:Debug(("harvested %d toy ids"):format(#ids))
	end
	return cache.ids
end

local function ScanToys(out, ctx)
	local ids = HarvestToyIDs()
	if not ids then return end

	for _, itemID in ipairs(ids) do
		if not ns.Try(PlayerHasToy, itemID) then
			local _, toyName, icon = ns.Try(C_ToyBox.GetToyInfo, itemID)
			if toyName then
				local parsed = ns.Sources:Resolve("toy", itemID, function()
					return ns.Sources:ItemTooltipText(itemID)
				end)

				if not (ns.db.collections.hideUnobtainable and not ns.Sources:IsRoutable(parsed.sourceKey)) then
					local entry = {
						key       = "toy:" .. itemID,
						module    = "collections",
						category  = "toys",
						id        = itemID,
						name      = toyName,
						icon      = icon,
						typeLabel = "Toy",
						itemID    = itemID,
					}
					ApplyParsed(entry, parsed)
					if ZoneGate(entry, parsed) then table.insert(out, entry) end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Battle pets
--
-- Species ids are enumerable directly, which avoids touching the Pet Journal
-- filters at all. The valid id list is cached after the first sweep.
--------------------------------------------------------------------------

local MAX_SPECIES_ID = 5000

local function PetSpeciesList()
	ns.db.cache.pets = ns.db.cache.pets or {}
	return ns.db.cache.pets.species
end

-- Chunked, because sweeping 5000 species ids in one frame is a visible stall.
local function BuildPetSpecies()
	ns.db.cache.pets = ns.db.cache.pets or {}
	if ns.db.cache.pets.species then return end

	local species = {}
	local id = 0
	ns:RunTask("ZC:PetSpecies", function()
		local stop = math.min(id + 250, MAX_SPECIES_ID)
		while id < stop do
			id = id + 1
			local name = ns.Try(C_PetJournal.GetPetInfoBySpeciesID, id)
			if name and name ~= "" then table.insert(species, id) end
		end
		return id < MAX_SPECIES_ID
	end, function()
		if #species > 0 then
			ns.db.cache.pets.species = species
			ns:Debug(("indexed %d pet species"):format(#species))
		end
	end)
end

local function ScanPets(out, ctx)
	local species = PetSpeciesList()
	if not species then return end

	for _, speciesID in ipairs(species) do
		local numCollected = ns.Try(C_PetJournal.GetNumCollectedInfo, speciesID)
		if numCollected == 0 then
			local name, icon, petType, _, tooltipSource, _, isWild, canBattle,
			      _, _, obtainable = ns.Try(C_PetJournal.GetPetInfoBySpeciesID, speciesID)

			if name and (obtainable ~= false or not ns.db.collections.hideUnobtainable) then
				local parsed = ns.Sources:Resolve("pet", speciesID, function() return tooltipSource end)

				if not (ns.db.collections.hideUnobtainable and not ns.Sources:IsRoutable(parsed.sourceKey)) then
					local entry = {
						key       = "pet:" .. speciesID,
						module    = "collections",
						category  = "pets",
						id        = speciesID,
						name      = name,
						icon      = icon,
						typeLabel = isWild and "Wild Pet" or "Pet",
						isWild    = isWild,
					}
					ApplyParsed(entry, parsed)
					if ZoneGate(entry, parsed) then table.insert(out, entry) end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Transmog sets
--------------------------------------------------------------------------

local function ScanTransmogSets(out, ctx)
	local sets = ns.Try(C_TransmogSets.GetAllSets)
	if type(sets) ~= "table" then return end

	for _, set in ipairs(sets) do
		if set and not set.collected and set.name then
			local blob = table.concat({ set.name, set.description or "", set.label or "" }, "\n")
			local parsed = ns.Sources:Resolve("tmogset", set.setID, function() return blob end)

			local entry = {
				key       = "tmogset:" .. set.setID,
				module    = "collections",
				category  = "transmogsets",
				id        = set.setID,
				name      = set.name,
				icon      = 134400, -- Interface\Icons\INV_Misc_QuestionMark
				typeLabel = "Transmog Set",
				detail    = set.description or set.label,
			}
			entry.mapID    = parsed.mapID
			entry.zoneName = parsed.zoneName
			if ZoneGate(entry, parsed) then table.insert(out, entry) end
		end
	end
end

--------------------------------------------------------------------------
-- Heirlooms
--------------------------------------------------------------------------

local function ScanHeirlooms(out, ctx)
	local ids = ns.Try(C_Heirloom.GetHeirloomIDs)
	if type(ids) ~= "table" then return end

	for _, itemID in ipairs(ids) do
		if not ns.Try(C_Heirloom.PlayerHasHeirloom, itemID) then
			local name, _, _, icon = ns.Try(C_Heirloom.GetHeirloomInfo, itemID)
			if name then
				local parsed = ns.Sources:Resolve("heirloom", itemID, function()
					return ns.Sources:ItemTooltipText(itemID)
				end)

				local entry = {
					key       = "heirloom:" .. itemID,
					module    = "collections",
					category  = "heirlooms",
					id        = itemID,
					itemID    = itemID,
					name      = name,
					icon      = icon,
					typeLabel = "Heirloom",
				}
				ApplyParsed(entry, parsed)
				if ZoneGate(entry, parsed) then table.insert(out, entry) end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Titles
--
-- No source data exists for titles, so they never carry a zone and only
-- appear at world reach. Included because "everything I am missing" is a
-- reasonable thing to want in one list.
--------------------------------------------------------------------------

local function ScanTitles(out, ctx)
	if ns.db.reach ~= "world" then return end

	local num = ns.Try(GetNumTitles) or 0
	for i = 1, num do
		if ns.Try(IsTitleKnown, i) == false then
			local name = ns.Try(GetTitleName, i)
			if name and name:gsub("%s", "") ~= "" then
				table.insert(out, {
					key       = "title:" .. i,
					module    = "collections",
					category  = "titles",
					id        = i,
					name      = (name:gsub("^%s+", ""):gsub("%s+$", "")),
					icon      = "Interface\\Icons\\Achievement_PVP_A_A",
					typeLabel = "Title",
					detail    = "Unearned title",
				})
			end
		end
	end
end

--------------------------------------------------------------------------
-- Provider entry points
--------------------------------------------------------------------------

-- Each collection type is its own provider so the chunked scan runner can
-- yield between them; doing all six in one call is a 100ms frame spike.
local DEFS = {
	{ key = "mounts",       label = "Mounts",        scan = ScanMounts },
	{ key = "toys",         label = "Toys",          scan = ScanToys },
	{ key = "pets",         label = "Battle Pets",   scan = ScanPets },
	{ key = "transmogsets", label = "Transmog Sets", scan = ScanTransmogSets },
	{ key = "heirlooms",    label = "Heirlooms",     scan = ScanHeirlooms },
	{ key = "titles",       label = "Titles",        scan = ScanTitles },
}

local prepared = false
local function PrepareShared()
	if prepared then return end
	prepared = true
	BuildPetSpecies()
	C_Timer.After(2, function() HarvestToyIDs() end)
end

for _, def in ipairs(DEFS) do
	local provider = {
		key     = "col_" .. def.key,
		label   = def.label,
		filters = { def.key },
		Prepare = PrepareShared,
		Scan    = function(_, ctx)
			local out = {}
			ns.Try(def.scan, out, ctx)
			return out
		end,
	}
	ns:RegisterProvider(provider)
	Collections[def.key] = provider
end

--------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------

local function Bump()
	if ns.db and ns.db.autoRescan then
		C_Timer.After(2, function() ns:Fire("REQUEST_SCAN", true) end)
	end
end

ns:RegisterEvent("NEW_MOUNT_ADDED", Bump)
ns:RegisterEvent("NEW_TOY_ADDED", Bump)
ns:RegisterEvent("NEW_PET_ADDED", Bump)
ns:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_ADDED", Bump)
