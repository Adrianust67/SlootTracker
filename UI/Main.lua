--[[--------------------------------------------------------------------------
	SlootTracker - UI/Main.lua

	The window: reach selector, category filters, the planned route strip, and
	the ranked list. Scope lives in settings - nobody changes it twice.

	The list is a hand-rolled recycling scroller rather than a ScrollBox. It
	only ever creates as many row frames as fit on screen, and it survives
	template churn between patches.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local UI = {}
ns.UI = UI

-- Rows have two shapes. Wide enough, and every column fits on one line. Narrow,
-- and five columns simply do not fit - so the zone and the progress bar step
-- aside, the row grows, and the description is allowed to wrap into the space
-- they left. Wrapping inside the short row was never an option: a second line
-- would render straight over the row below it.
local ROW_H_WIDE     = 28
local ROW_H_NARROW   = 46
local NARROW_BELOW   = 700

local rowHeight  = ROW_H_WIDE
local narrowMode = false

local LIST_BOTTOM    = 30

-- Filter grid geometry. The number of columns is derived from the window
-- width at layout time rather than hardcoded, so narrowing the window reflows
-- the checkboxes instead of pushing the rightmost column off the edge.
local FILTER_TOP   = 68    -- distance from the top of the frame
local FILTER_COL_W = 128
local FILTER_ROW_H = 22
local ROUTE_H      = 42

-- Distance from the top of the frame to the top of the list. Recomputed by
-- LayoutPanels because the filter block grows taller as the window narrows.
local listTopInset = 168

local CATEGORY_COLORS = {
	achievements = { 0.95, 0.80, 0.20 },
	exploration  = { 0.45, 0.85, 0.55 },
	treasures    = { 1.00, 0.55, 0.25 },
	mounts       = { 0.85, 0.45, 0.95 },
	toys         = { 0.40, 0.90, 0.90 },
	pets         = { 0.70, 0.90, 0.40 },
	transmogsets = { 0.90, 0.60, 0.70 },
	heirlooms    = { 0.60, 0.75, 0.95 },
	titles       = { 0.80, 0.80, 0.80 },
	decor        = { 0.95, 0.70, 0.45 },
}

-- Quests are deliberately absent. The game only ever exposes the quests it is
-- currently offering you, never the full set for a zone, so a "Quests" column
-- in a completion tracker promised more than it could deliver. The quest log
-- and objective tracker already cover what the client actually knows.
local FILTER_ORDER = {
	{ key = "achievements", label = "Achievements" },
	{ key = "exploration",  label = "Exploration" },
	{ key = "treasures",    label = "Treasures" },
	{ key = "mounts",       label = "Mounts" },
	{ key = "toys",         label = "Toys" },
	{ key = "pets",         label = "Pets" },
	{ key = "transmogsets", label = "Transmog" },
	{ key = "heirlooms",    label = "Heirlooms" },
	{ key = "titles",       label = "Titles" },
	{ key = "decor",        label = "Decor" },
}

local frame, rows, slider, scrollOffset = nil, {}, nil, 0
local visibleRows = 12
local displayed = {}   -- filtered view of Priority.entries

--------------------------------------------------------------------------
-- Small widget helpers
--------------------------------------------------------------------------

local function CategoryColor(entry)
	local c = CATEGORY_COLORS[entry.category or entry.module] or { 0.8, 0.8, 0.8 }
	return c[1], c[2], c[3]
end

-- Who you are logged in as, in class colour. Resolved once and remembered:
-- the name and class cannot change while you are playing this character.
local playerLabel
local function ColouredPlayerName()
	if playerLabel then return playerLabel end

	local name = ns.playerName or UnitName("player")
	if not name then return "" end

	local _, class = UnitClass("player")
	local colour = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	local hex = colour and (colour.colorStr
		or (colour.r and ("ff%02x%02x%02x"):format(
			math.floor(colour.r * 255), math.floor(colour.g * 255), math.floor(colour.b * 255))))

	playerLabel = hex and ("|c%s%s|r"):format(hex, name) or name
	return playerLabel
end

local function FormatDistance(entry)
	if not entry.distance then return nil end

	-- A leading tilde marks a distance measured to the middle of a zone rather
	-- than to an actual spot, so a rough number is never mistaken for a precise
	-- one.
	local prefix = entry.approximateDistance and "~" or ""
	if entry.distance < 1000 then
		return ("%s%d yd"):format(prefix, entry.distance)
	end
	return ("%s%.1f k"):format(prefix, entry.distance / 1000)
end

-- Dropdown-ish button. Uses the modern menu system where present and falls
-- back to click-to-cycle so the control is never dead.
local function CreateSelector(parent, width, getLabel, buildMenu, cycle)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)

	function button:Sync() self:SetText(getLabel()) end

	button:SetScript("OnClick", function(self)
		if MenuUtil and MenuUtil.CreateContextMenu then
			MenuUtil.CreateContextMenu(self, function(_, root)
				buildMenu(root, function()
					self:Sync()
					ns:Fire("REQUEST_SCAN", true)
				end)
			end)
		else
			cycle()
			self:Sync()
			ns:Fire("REQUEST_SCAN", true)
		end
	end)

	button:Sync()
	return button
end

--------------------------------------------------------------------------
-- Filtering the scored list
--------------------------------------------------------------------------

local function RebuildDisplayed()
	wipe(displayed)
	local ignored = ns.db.ignored or {}

	for _, entry in ipairs(ns.Priority.entries) do
		if not ignored[entry.key] then
			table.insert(displayed, entry)
		end
	end
end

--------------------------------------------------------------------------
-- Row construction
--------------------------------------------------------------------------

local function ShowRowTooltip(row)
	local entry = row.entry
	if not entry then return end

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(entry.name or "?", 1, 1, 1)

	if entry.typeLabel then
		local r, g, b = CategoryColor(entry)
		GameTooltip:AddLine(entry.typeLabel, r, g, b)
	end
	if entry.detail then
		GameTooltip:AddLine(entry.detail, 0.8, 0.8, 0.8, true)
	end

	GameTooltip:AddLine(" ")
	if entry.zoneName then
		local line = entry.zoneName
		if entry.x and entry.y then
			line = ("%s  (%.1f, %.1f)"):format(line, entry.x * 100, entry.y * 100)
		end
		GameTooltip:AddDoubleLine("Location", line, 0.6, 0.6, 0.6, 1, 1, 1)
		if entry.approximate then
			GameTooltip:AddLine("Approximate - head to this area and look around.", 0.7, 0.7, 0.7)
		end
	end
	local dist = FormatDistance(entry)
	if dist then
		GameTooltip:AddDoubleLine("Distance", dist, 0.6, 0.6, 0.6, 1, 1, 1)
	end
	if entry.have and entry.need then
		GameTooltip:AddDoubleLine("Progress", ("%d / %d"):format(entry.have, entry.need), 0.6, 0.6, 0.6, 1, 1, 1)
	end
	if entry.points and entry.points > 0 then
		local line = ("%d"):format(entry.points)
		if entry.pointsPerStep and entry.need and entry.have and (entry.need - entry.have) > 1 then
			line = ("%d  (%.1f per step left)"):format(entry.points, entry.pointsPerStep)
		end
		GameTooltip:AddDoubleLine("Achievement points", line, 0.6, 0.6, 0.6, 1, 0.82, 0)
	end
	if entry.earnedByAlt then
		GameTooltip:AddLine("Already earned on another character.", 1, 0.6, 0.2)
	end
	if entry.doneByAlt then
		GameTooltip:AddLine("Another character has explored this; you have not.", 1, 0.6, 0.2)
	end
	if entry.sharedCriteria then
		GameTooltip:AddLine("The game stores this credit account-wide.", 0.6, 0.6, 0.6)
	end
	if entry.costText then
		local r, g, b = 0.7, 0.7, 0.7
		if entry.affordable == true then r, g, b = 0.4, 1, 0.4
		elseif entry.affordable == false then r, g, b = 1, 0.5, 0.25 end
		GameTooltip:AddDoubleLine("Cost", entry.costText, 0.6, 0.6, 0.6, r, g, b)
		if entry.affordable == false then
			GameTooltip:AddLine("You cannot afford this yet.", 1, 0.5, 0.25)
		end
	end
	if entry.locked then
		GameTooltip:AddLine(entry.lockNote or "Locked behind a key or attunement.", 1, 0.5, 0.25, true)
		GameTooltip:AddLine("Ranked lower because you cannot just walk up to it.", 0.6, 0.6, 0.6)
	end
	if entry.stepsAway and entry.stepsAway > 0 then
		local label = entry.isMeta and "Achievements in the way" or "Steps remaining"
		GameTooltip:AddDoubleLine(label, tostring(entry.stepsAway), 0.6, 0.6, 0.6, 1, 1, 1)
	end
	if entry.metaRemaining and entry.metaRemaining > 0 then
		if entry.metaTier and entry.metaTier > 1 then
			GameTooltip:AddDoubleLine("Chain depth",
				("%d tiers of achievements"):format(entry.metaTier), 0.6, 0.6, 0.6, 1, 0.5, 0.25)
		end
		GameTooltip:AddLine("Earned by completing other achievements - ranked lower until "
			.. "those are done.", 1, 0.5, 0.25, true)
	end

	-- Why is this ranked here?
	local p = entry.scoreParts
	if p and ns.db.debug then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Score", ("%.0f"):format(entry.score or 0), 0.6, 0.6, 0.6, 1, 0.82, 0)
		GameTooltip:AddDoubleLine("  reach tier", tostring(entry.tier), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  map", ("%s (%s)"):format(
			tostring(entry.mapID), entry.zoneName or "?"), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  weight x proximity",
			("%.2f x %.2f"):format(p.weight, p.proximity), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  precision",
			("%.2f"):format(p.precision or 1), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  progress x urgency",
			("%.2f x %.2f"):format(p.progress, p.urgency), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  points",
			("%.2f"):format(p.points or 1), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
	end

	GameTooltip:AddLine(" ")
	if entry.x and entry.y then
		GameTooltip:AddLine("Left-click: set waypoint", 0.4, 0.8, 0.4)
	elseif entry.mapID then
		GameTooltip:AddLine("Left-click: waypoint to the middle of the zone", 0.4, 0.8, 0.4)
	end
	GameTooltip:AddLine("Shift-click: link in chat", 0.4, 0.8, 0.4)
	GameTooltip:AddLine("Right-click: more options", 0.4, 0.8, 0.4)
	GameTooltip:Show()
end

local function OpenEntry(entry)
	if entry.module == "achievements" or entry.module == "exploration" then
		if not AchievementFrame then ns.Try(AchievementFrame_LoadUI) end
		if AchievementFrame then
			ShowUIPanel(AchievementFrame)
			ns.Try(AchievementFrame_SelectAchievement, entry.id)
		end
	elseif entry.category == "mounts" or entry.category == "pets" or entry.category == "toys" then
		ns.Try(function() ToggleCollectionsJournal(entry.category == "mounts" and 1
			or entry.category == "pets" and 2 or 3) end)
	end
end

local function RowContextMenu(row)
	local entry = row.entry
	if not entry then return end

	local function Build(_, root)
		root:CreateTitle(entry.name or "Entry")

		local mapID, wx, wy, rough = ns.Location:BestPosition(entry)
		if mapID then
			root:CreateButton(rough and "Set waypoint (zone centre)" or "Set waypoint", function()
				ns.Location:SetWaypoint(mapID, wx, wy, entry.name, rough)
			end)
		end
		root:CreateButton("Open in game UI", function() OpenEntry(entry) end)

		if entry.link then
			root:CreateButton("Link in chat", function()
				ChatEdit_InsertLink(entry.link)
			end)
		end

		if entry.trackType and C_ContentTracking then
			root:CreateButton("Track", function()
				ns.Try(C_ContentTracking.StartTracking, entry.trackType, entry.id)
			end)
		end

		root:CreateDivider()
		root:CreateButton("Ignore this", function()
			ns.db.ignored = ns.db.ignored or {}
			ns.db.ignored[entry.key] = true
			UI:Refresh()
		end)
		root:CreateButton(("Hide all %s"):format(entry.typeLabel or entry.category or "of these"), function()
			local key = entry.category or entry.module
			if ns.db.filters[key] ~= nil then
				ns.db.filters[key] = false
				UI:SyncFilters()
				ns:Fire("REQUEST_SCAN", true)
			end
		end)
	end

	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(row, Build)
	else
		-- No menu system: fall back to the most useful single action.
		if entry.x and entry.y then
			ns.Location:SetWaypoint(entry.mapID, entry.x, entry.y, entry.name)
		else
			OpenEntry(entry)
		end
	end
end

local function CreateRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.03 or 0.06)

	row.stripe = row:CreateTexture(nil, "ARTWORK")
	row.stripe:SetPoint("TOPLEFT", 0, -1)
	row.stripe:SetPoint("BOTTOMLEFT", 0, 1)
	row.stripe:SetWidth(3)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(24, 24)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.rank:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.rank:SetWidth(24)
	row.rank:SetJustifyH("RIGHT")

	-- The right-hand block is created first so the name and detail can anchor
	-- their right edge to it and stretch with the window. They used to be a
	-- fixed 300px, which meant a wide window still wrapped them onto a second
	-- line inside a fixed-height row.
	row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.zone:SetPoint("RIGHT", -90, 6)
	row.zone:SetJustifyH("RIGHT")
	row.zone:SetWidth(160)
	row.zone:SetWordWrap(false)

	row.dist = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.dist:SetPoint("RIGHT", -90, -6)
	row.dist:SetJustifyH("RIGHT")
	row.dist:SetWidth(160)
	row.dist:SetWordWrap(false)

	-- Single line each, ellipsised. A row is a fixed height, so wrapping could
	-- only ever spill into the row below.
	-- Anchored to the row, not to the rank text: the rank is vertically centred,
	-- so hanging the name off it made the text block's position depend on the
	-- rank font's height and pushed it below centre.
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 66, -3)
	row.name:SetPoint("RIGHT", row.zone, "LEFT", -10, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
	row.detail:SetPoint("RIGHT", row.zone, "LEFT", -10, 0)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)

	row.progress = CreateFrame("StatusBar", nil, row)
	row.progress:SetSize(72, 10)
	row.progress:SetPoint("RIGHT", -10, 0)
	row.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.progress:SetMinMaxValues(0, 1)
	row.progress.bg = row.progress:CreateTexture(nil, "BACKGROUND")
	row.progress.bg:SetAllPoints()
	row.progress.bg:SetColorTexture(0, 0, 0, 0.5)
	row.progress.text = row.progress:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.progress.text:SetPoint("CENTER")

	row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(1, 1, 1, 0.10)

	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:SetScript("OnClick", function(self, button)
		local entry = self.entry
		if not entry then return end

		if IsShiftKeyDown() and entry.link then
			ChatEdit_InsertLink(entry.link)
			return
		end
		if button == "RightButton" then
			RowContextMenu(self)
			return
		end
		-- Clicking anything with a known zone should point you at it. Falling
		-- through to the collections journal for everything without exact
		-- coordinates meant vendor and drop mounts did nothing useful.
		local mapID, x, y, rough = ns.Location:BestPosition(entry)
		if mapID then
			ns.Location:SetWaypoint(mapID, x, y, entry.name, rough)
		else
			OpenEntry(entry)
		end
	end)

	return row
end

local function UpdateRow(row, entry, rank)
	row.entry = entry
	if not entry then row:Hide() return end

	local r, g, b = CategoryColor(entry)
	row.stripe:SetColorTexture(r, g, b, 0.9)

	-- entry.atlas is an atlas name; entry.icon is a fileID or a texture path.
	-- Conflating the two renders a blank square, so they stay separate fields.
	if entry.atlas then
		row.icon:SetTexCoord(0, 1, 0, 1)
		local ok = pcall(row.icon.SetAtlas, row.icon, entry.atlas)
		if not ok then
			row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			row.icon:SetTexture(entry.icon or 134400)
		end
	else
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.icon:SetTexture(entry.icon or 134400)
	end

	row.rank:SetText(entry.routeStep and ("|cff40ff40#%d|r"):format(entry.routeStep) or tostring(rank))

	row.name:SetText(entry.name or "?")
	row.name:SetTextColor(r, g, b)

	-- The narrow shape has no zone column, so the zone rides along at the front
	-- of the description rather than being lost. Skipped when it is the zone you
	-- are already standing in, which would just be noise.
	local detail = entry.detail or ""
	if narrowMode and entry.zoneName and entry.tier ~= "here" then
		detail = ("|cff9d9d9d%s|r  %s"):format(entry.zoneName, detail)
	end
	row.detail:SetText(detail)

	row.zone:SetText(entry.zoneName or "")
	local dist = FormatDistance(entry)
	row.dist:SetText(dist or (entry.tier == "continent" and "this continent" or "this zone"))

	-- A vague lead must never look like a precise one at a glance: dimmed and
	-- tilde-prefixed when all we know is the zone.
	if entry.x and entry.y then
		row.dist:SetTextColor(0.85, 0.85, 0.85)
	else
		row.dist:SetTextColor(0.5, 0.5, 0.5)
	end

	if entry.have and entry.need and entry.need > 1 and not narrowMode then
		row.progress:Show()
		row.progress:SetValue((entry.progress or 0))
		row.progress:SetStatusBarColor(r, g, b)
		row.progress.text:SetText(("%d/%d"):format(entry.have, entry.need))
	else
		row.progress:Hide()
	end

	row:Show()
end

--------------------------------------------------------------------------
-- Scrolling
--------------------------------------------------------------------------

local function UpdateScroll()
	local total = #displayed
	local maxOffset = math.max(0, total - visibleRows)
	scrollOffset = math.max(0, math.min(scrollOffset, maxOffset))

	slider:SetMinMaxValues(0, maxOffset)
	slider:SetValue(scrollOffset)
	slider:SetShown(maxOffset > 0)

	for i = 1, visibleRows do
		local row = rows[i]
		if row then
			UpdateRow(row, displayed[i + scrollOffset], i + scrollOffset)
		end
	end
	for i = visibleRows + 1, #rows do
		if rows[i] then rows[i]:Hide() end
	end
end

-- Reflow the filter checkboxes for the current width, then push the route
-- strip and the list down to clear however many rows that produced.
local function LayoutPanels()
	if not frame or not frame.filterOrder then return end

	-- Row shape is a width decision, same as the filter grid.
	narrowMode = frame:GetWidth() < NARROW_BELOW
	rowHeight  = narrowMode and ROW_H_NARROW or ROW_H_WIDE

	local usable = frame:GetWidth() - 32

	-- Measure the widest label rather than trusting a fixed column width: the
	-- constant was narrower than "Achievements" renders at some UI scales, so
	-- columns ran into each other as the window shrank.
	local widest = 0
	for _, check in ipairs(frame.filterOrder) do
		if check.text then
			local w = check.text:GetStringWidth() or 0
			if w > widest then widest = w end
		end
	end
	local colWidth = math.max(FILTER_COL_W, math.ceil(widest) + 34)

	-- One column is a legitimate outcome on a very narrow window; forcing two
	-- is what guaranteed the overlap.
	local columns = math.max(1, math.floor(usable / colWidth))
	local gridRows = math.ceil(#frame.filterOrder / columns)

	for i, check in ipairs(frame.filterOrder) do
		local col = (i - 1) % columns
		local row = math.floor((i - 1) / columns)
		check:ClearAllPoints()
		check:SetPoint("TOPLEFT", 16 + col * colWidth, -(FILTER_TOP + row * FILTER_ROW_H))
	end

	local filterBottom = FILTER_TOP + gridRows * FILTER_ROW_H

	if frame.route then
		frame.route:ClearAllPoints()
		frame.route:SetPoint("TOPLEFT", 16, -(filterBottom + 6))
		frame.route:SetPoint("TOPRIGHT", -16, -(filterBottom + 6))
	end

	listTopInset = filterBottom + 6 + ROUTE_H + 8

	if frame.list then
		frame.list:ClearAllPoints()
		frame.list:SetPoint("TOPLEFT", 14, -listTopInset)
		frame.list:SetPoint("BOTTOMRIGHT", -30, LIST_BOTTOM)
	end
	if slider then
		slider:ClearAllPoints()
		slider:SetPoint("TOPRIGHT", -14, -listTopInset)
		slider:SetPoint("BOTTOMRIGHT", -14, LIST_BOTTOM)
	end
end

-- Re-anchor a row's contents for the current shape. Called whenever rows are
-- laid out, so a resize past the threshold reshapes every existing row rather
-- than only the ones created afterwards.
local function ApplyRowShape(row)
	row:SetHeight(rowHeight)

	row.zone:SetShown(not narrowMode)
	row.name:ClearAllPoints()
	row.detail:ClearAllPoints()
	row.dist:ClearAllPoints()

	if narrowMode then
		-- Distance keeps its corner; the zone column goes entirely. The
		-- description then gets the full width of the row to wrap into.
		row.dist:SetPoint("TOPRIGHT", -10, -4)
		row.dist:SetWidth(90)

		row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 66, -4)
		row.name:SetPoint("RIGHT", row.dist, "LEFT", -8, 0)

		row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", 34, -20)
		row.detail:SetPoint("RIGHT", row, "RIGHT", -10, 0)
		row.detail:SetWordWrap(true)
		if row.detail.SetMaxLines then row.detail:SetMaxLines(2) end
	else
		row.dist:SetPoint("RIGHT", -90, -6)
		row.dist:SetWidth(160)

		row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 66, -3)
		row.name:SetPoint("RIGHT", row.zone, "LEFT", -10, 0)

		row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
		row.detail:SetPoint("RIGHT", row.zone, "LEFT", -10, 0)
		row.detail:SetWordWrap(false)
		if row.detail.SetMaxLines then row.detail:SetMaxLines(1) end
	end
end

local function LayoutRows()
	local height = frame:GetHeight() - listTopInset - LIST_BOTTOM
	visibleRows = math.max(1, math.floor(height / rowHeight))

	for i = 1, visibleRows do
		if not rows[i] then rows[i] = CreateRow(frame.list, i) end
		local row = rows[i]
		ApplyRowShape(row)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.list, "TOPLEFT", 0, -(i - 1) * rowHeight)
		row:SetPoint("RIGHT", frame.list, "RIGHT", 0, 0)
	end
	UpdateScroll()
end

--------------------------------------------------------------------------
-- Route strip
--------------------------------------------------------------------------

local function UpdateRoute()
	local route = ns.Priority.route
	local strip = frame.route

	if not ns.db.route.enabled or #route == 0 then
		strip.label:SetText("|cff888888No routable objectives with coordinates in reach.|r")
		for _, chip in ipairs(strip.chips) do chip:Hide() end
		return
	end

	local total = 0
	for _, entry in ipairs(route) do total = total + (entry.routeDistance or 0) end
	strip.label:SetText(("|cffffd100Route|r  %d stops, ~%d yards"):format(#route, total))

	for i = 1, #strip.chips do strip.chips[i]:Hide() end
	local x = 0
	for i, entry in ipairs(route) do
		local chip = strip.chips[i]
		if not chip then
			chip = CreateFrame("Button", nil, strip)
			chip:SetHeight(18)
			chip.text = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			chip.text:SetPoint("LEFT", 4, 0)
			chip.bg = chip:CreateTexture(nil, "BACKGROUND")
			chip.bg:SetAllPoints()
			chip:SetScript("OnClick", function(self)
				if self.entry then
					ns.Location:SetWaypoint(self.entry.mapID, self.entry.x, self.entry.y, self.entry.name)
				end
			end)
			chip:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
				GameTooltip:AddLine(self.entry and self.entry.name or "")
				GameTooltip:AddLine(("%d yards from the previous stop"):format(self.entry and self.entry.routeDistance or 0), 0.7, 0.7, 0.7)
				GameTooltip:AddLine("Click to set a waypoint", 0.4, 0.8, 0.4)
				GameTooltip:Show()
			end)
			chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
			strip.chips[i] = chip
		end

		chip.entry = entry
		local short = (entry.name or "?"):sub(1, 18)
		chip.text:SetText(("|cffffd100%d.|r %s"):format(i, short))
		chip:SetWidth(chip.text:GetStringWidth() + 12)
		local r, g, b = CategoryColor(entry)
		chip.bg:SetColorTexture(r, g, b, 0.18)

		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", strip, "TOPLEFT", x, -18)
		x = x + chip:GetWidth() + 4
		chip:Show()

		if x > strip:GetWidth() - 60 then break end
	end
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

function UI:Build()
	if frame then return frame end

	frame = CreateFrame("Frame", "SlootTrackerFrame", UIParent, "BackdropTemplate")
	frame:SetSize(ns.db.window.width, ns.db.window.height)
	frame:SetPoint(ns.db.window.point, UIParent, ns.db.window.relPoint, ns.db.window.x, ns.db.window.y)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")
	-- Floor chosen so the filter grid always has room for at least three
	-- readable columns. There is no value in letting it shrink past legible.
	if frame.SetResizeBounds then frame:SetResizeBounds(560, 340) end

	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 28,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		})
	end

	-- Never registered in UISpecialFrames: that list is for modal panels you
	-- dismiss with Escape, and a persistent tracker is not one. You press
	-- Escape constantly while playing. Close it with the X in the corner.

	-- Title bar / dragging
	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT", 8, -8)
	titleBar:SetPoint("TOPRIGHT", -8, -8)
	titleBar:SetHeight(26)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint()
		ns.db.window.point, ns.db.window.relPoint = point, relPoint
		ns.db.window.x, ns.db.window.y = x, y
	end)

	frame.title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.title:SetPoint("LEFT", 6, 0)
	frame.title:SetText("|cff5bc0f5Sloot Tracker|r")

	-- Version and author, pulled from the TOC so they can never drift out of
	-- sync with what was actually packaged. Sits at the right end of the title
	-- bar, clear of the close button.
	frame.credit = titleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.credit:SetPoint("RIGHT", -28, 0)
	frame.credit:SetJustifyH("RIGHT")
	frame.credit:SetWordWrap(false)
	frame.credit:SetText(("v%s  |cff707070by|r %s"):format(ns.version, ns.author))

	frame.zoneLabel = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.zoneLabel:SetPoint("LEFT", frame.title, "RIGHT", 10, 0)
	frame.zoneLabel:SetPoint("RIGHT", frame.credit, "LEFT", -10, 0)
	frame.zoneLabel:SetJustifyH("LEFT")
	frame.zoneLabel:SetWordWrap(false)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Resize grip
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -6, 6)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		ns.db.window.width, ns.db.window.height = frame:GetWidth(), frame:GetHeight()
		LayoutRows()
	end)

	--------------------------------------------------------------------
	-- Control row: scope, reach, search, actions
	--------------------------------------------------------------------

	local REACH_LABEL = { zone = "Reach: This zone", continent = "Reach: Continent", world = "Reach: Everywhere" }
	frame.reach = CreateSelector(frame, 150,
		function() return REACH_LABEL[ns.db.reach] or "Reach" end,
		function(root, done)
			root:CreateTitle("How far to look")
			root:CreateButton("This zone only", function() ns.db.reach = "zone";      done() end)
			root:CreateButton("This continent", function() ns.db.reach = "continent"; done() end)
			root:CreateButton("Everywhere",     function() ns.db.reach = "world";     done() end)
		end,
		function()
			ns.db.reach = (ns.db.reach == "zone" and "continent")
			           or (ns.db.reach == "continent" and "world") or "zone"
		end)
	frame.reach:SetPoint("TOPLEFT", 16, -38)

	-- No Settings button here on purpose: everything configurable lives in the
	-- game's own options panel (Esc > Options > AddOns > Sloot Tracker), or
	-- /sloot config, or right-clicking the minimap button.
	local rescan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	rescan:SetSize(80, 22)
	rescan:SetPoint("TOPRIGHT", -16, -38)
	rescan:SetText("Rescan")
	rescan:SetScript("OnClick", function() ns:Fire("REQUEST_SCAN", true) end)

	--------------------------------------------------------------------
	-- Category filter checkboxes (two rows of five)
	--------------------------------------------------------------------

	frame.filterButtons = {}
	frame.filterOrder = {}
	for i, def in ipairs(FILTER_ORDER) do
		local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		check:SetSize(22, 22)
		-- LayoutPanels reflows these, but anchor them here too: a frame with no
		-- anchor renders nowhere at all, so if layout ever fails to run the
		-- checkboxes must not vanish and take the only recovery UI with them.
		check:SetPoint("TOPLEFT", 16 + ((i - 1) % 5) * FILTER_COL_W,
			-(FILTER_TOP + math.floor((i - 1) / 5) * FILTER_ROW_H))
		check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		check.text:SetPoint("LEFT", check, "RIGHT", 1, 0)
		check.text:SetText(def.label)

		local c = CATEGORY_COLORS[def.key]
		if c then check.text:SetTextColor(c[1], c[2], c[3]) end

		check:SetScript("OnClick", function(self)
			ns.db.filters[def.key] = self:GetChecked() and true or false
			ns:Fire("REQUEST_SCAN", true)
		end)
		frame.filterButtons[def.key] = check
		frame.filterOrder[i] = check
	end

	--------------------------------------------------------------------
	-- Route strip
	--------------------------------------------------------------------

	local strip = CreateFrame("Frame", nil, frame)
	strip:SetPoint("TOPLEFT", 16, -116)
	strip:SetPoint("TOPRIGHT", -16, -116)
	strip:SetHeight(42)
	strip.chips = {}
	strip.label = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	strip.label:SetPoint("TOPLEFT", 0, 0)
	frame.route = strip

	--------------------------------------------------------------------
	-- List area
	--------------------------------------------------------------------

	local list = CreateFrame("Frame", nil, frame)
	list:SetPoint("TOPLEFT", 14, -listTopInset)
	list:SetPoint("BOTTOMRIGHT", -30, LIST_BOTTOM)
	frame.list = list

	slider = ns.CreateVerticalScrollBar(frame)
	slider:SetPoint("TOPRIGHT", -14, -listTopInset)
	slider:SetPoint("BOTTOMRIGHT", -14, LIST_BOTTOM)
	slider:SetScript("OnValueChanged", function(_, value)
		scrollOffset = math.floor(value + 0.5)
		UpdateScroll()
	end)

	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		scrollOffset = scrollOffset - delta * 3
		UpdateScroll()
	end)

	--------------------------------------------------------------------
	-- Footer
	--------------------------------------------------------------------

	-- The status string is created first so the counts string can anchor its
	-- right edge to it. Both are non-wrapping with a bounded width, so a long
	-- category list truncates with an ellipsis instead of sliding underneath
	-- the status text.
	frame.warning = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.warning:SetPoint("BOTTOMRIGHT", -30, 12)
	frame.warning:SetJustifyH("RIGHT")
	frame.warning:SetWordWrap(false)
	frame.warning:SetHeight(14)

	-- An empty list is nearly always the result of the player's own filters,
	-- so say which ones rather than showing a blank box.
	frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	-- Anchored to the frame, not the list: the list's own anchors are rewritten
	-- by LayoutPanels, and this message must survive a layout that went wrong.
	frame.empty:SetPoint("CENTER", frame, "CENTER", 0, -10)
	frame.empty:SetWidth(360)
	frame.empty:SetJustifyH("CENTER")
	frame.empty:SetTextColor(0.7, 0.7, 0.7)
	frame.empty:Hide()

	-- One click back to a working state. Hunting through settings to undo your
	-- own filters is exactly the moment people give up on an addon.
	frame.emptyFix = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	frame.emptyFix:SetSize(220, 24)
	frame.emptyFix:SetPoint("TOP", frame.empty, "BOTTOM", 0, -12)
	frame.emptyFix:SetText("Show me everything nearby")
	frame.emptyFix:Hide()
	frame.emptyFix:SetScript("OnClick", function()
		for _, def in ipairs(FILTER_ORDER) do
			ns.db.filters[def.key] = true
		end
		ns.db.reach = "continent"
		ns.db.collections.requireZoneMatch = false
		UI:SyncFilters()
		ns:Fire("REQUEST_SCAN", true)
		ns:Print("categories enabled, reach widened to this continent.")
	end)

	frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 16, 12)
	frame.footer:SetPoint("BOTTOMRIGHT", frame.warning, "BOTTOMLEFT", -12, 0)
	frame.footer:SetJustifyH("LEFT")
	frame.footer:SetWordWrap(false)
	frame.footer:SetHeight(14)

	frame:SetScript("OnSizeChanged", function(self)
		LayoutPanels()
		LayoutRows()
		-- Persist continuously, not just on grip release, so a size set by any
		-- means (including an external layout tool) survives a reload.
		local w, h = self:GetWidth(), self:GetHeight()
		if w >= 560 and h >= 340 then
			ns.db.window.width, ns.db.window.height = w, h
		end
	end)

	-- Hide first, THEN attach the state trackers: this initial Hide would
	-- otherwise fire OnHide and clobber the saved value before we restore it.
	local wasShown = ns.db.window.shown
	frame:Hide()

	-- Remember open/closed across sessions: closing with the X means it stays
	-- closed until you reopen it, which is the point of having the button.
	frame:SetScript("OnShow", function() ns.db.window.shown = true end)
	frame:SetScript("OnHide", function() ns.db.window.shown = false end)
	frame.restoreShown = wasShown

	self:SyncFilters()
	LayoutPanels()
	LayoutRows()
	return frame
end

--------------------------------------------------------------------------
-- Public refresh entry points
--------------------------------------------------------------------------

-- Re-apply the stored position. Used by the layout-tool integration, which
-- writes into the same db.window table the frame's own drag handler uses, so
-- there is only ever one source of truth for where the window sits.
function UI:ApplyStoredPosition()
	if not frame then return end
	local w = ns.db.window
	frame:ClearAllPoints()
	frame:SetPoint(w.point or "CENTER", UIParent, w.relPoint or "CENTER", w.x or 0, w.y or 0)
end

-- Size and position together, re-applied from the database.
--
-- Build already does this, but other addons initialise after us - a layout
-- manager reapplying its own idea of where our frame belongs, for instance -
-- and whatever runs last wins. Rather than guess who moved it, we simply put
-- it back once everything has settled.
function UI:RestoreGeometry()
	if not frame then return end
	local w = ns.db.window

	local width  = math.max(560, w.width or 820)
	local height = math.max(340, w.height or 560)
	frame:SetSize(width, height)
	self:ApplyStoredPosition()

	ns:Debug(("geometry restored: %dx%d at %s %d,%d"):format(
		width, height, w.point or "CENTER", w.x or 0, w.y or 0))
end

function UI:GetFrame()
	return frame
end

function UI:SyncFilters()
	if not frame then return end
	for key, check in pairs(frame.filterButtons) do
		check:SetChecked(ns.db.filters[key] and true or false)
	end
	if frame.reach then frame.reach:Sync() end
end

-- Explain a blank list. Nearly every empty result traces back to a filter the
-- player set themselves, so name the specific ones rather than showing nothing.
function UI:UpdateEmptyState()
	if not frame or not frame.empty then return end

	if #displayed > 0 then
		frame.empty:Hide()
		frame.emptyFix:Hide()
		return
	end

	if ns.Priority.scanning then
		frame.empty:SetText("Scanning...")
		frame.empty:Show()
		frame.emptyFix:Hide()
		return
	end

	local reasons = {}

	local off = {}
	for _, def in ipairs(FILTER_ORDER) do
		if not ns.db.filters[def.key] then table.insert(off, def.label) end
	end
	if #off > 0 then
		table.insert(reasons, "|cffffd100Filtered out:|r " .. table.concat(off, ", "))
	end

	if ns.db.reach == "zone" then
		table.insert(reasons, "|cffffd100Reach|r is limited to this zone - try Continent.")
	end

	if ns.db.collections.requireZoneMatch then
		local anyCollection = false
		for _, key in ipairs({ "mounts", "toys", "pets", "transmogsets", "heirlooms" }) do
			if ns.db.filters[key] then anyCollection = true end
		end
		if anyCollection then
			table.insert(reasons,
				"Collectibles are hidden unless their source names a zone (Settings > Collections).")
		end
	end

	if #reasons == 0 then
		frame.empty:SetText("Nothing left to do within reach.\n\n|cff888888Widen the reach, or enable more categories.|r")
	else
		frame.empty:SetText("Nothing to show here.\n\n" .. table.concat(reasons, "\n"))
	end
	frame.empty:Show()
	frame.emptyFix:Show()
end

function UI:Refresh()
	if not frame or not frame:IsShown() then return end

	local loc = ns.Location:Get()
	frame.zoneLabel:SetText(("|cffffd100%s|r%s  |cff707070|||r  %s"):format(
		loc.zoneName or "?",
		loc.subZone ~= "" and (" - " .. loc.subZone) or "",
		ColouredPlayerName()))

	RebuildDisplayed()
	UpdateScroll()

	-- Before the route strip, and isolated from it. This message is the only
	-- thing standing between an empty list and a user with no idea why, so an
	-- error anywhere else must not be able to suppress it.
	pcall(UI.UpdateEmptyState, UI)
	pcall(UpdateRoute)

	-- Footer: per-category counts, highest first.
	local parts, ordered = {}, {}
	for key, count in pairs(ns.Priority.stats) do
		table.insert(ordered, { key = key, count = count })
	end
	table.sort(ordered, function(a, b) return a.count > b.count end)
	for _, item in ipairs(ordered) do
		local c = CATEGORY_COLORS[item.key] or { 0.8, 0.8, 0.8 }
		table.insert(parts, ("|cff%02x%02x%02x%d %s|r"):format(
			math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255),
			item.count, item.key))
	end
	-- Truncation eats the right-hand end, so the most valuable numbers go
	-- first and the long per-category breakdown trails.
	local pointsText = ""
	if (ns.Priority.pointsAvailable or 0) > 0 then
		pointsText = ("|cffffd100%d pts|r  |  "):format(ns.Priority.pointsAvailable)
	end
	frame.footer:SetText(("%d shown  |  %s%s"):format(
		#displayed, pointsText, table.concat(parts, "  ")))

	if ns.Roster:AccountDataIsThin() then
		-- Kept short: this shares the bottom bar with the category counts.
		frame.warning:SetText("|cffff8040account scope: 1 char recorded|r")
	elseif ns.Priority.scanning then
		frame.warning:SetText("|cff888888scanning...|r")
	else
		frame.warning:SetText(("|cff888888%d characters recorded|r"):format(ns.Roster:CharacterCount()))
	end
end

--------------------------------------------------------------------------
-- Instances
--
-- Inside a dungeon, raid, delve or battleground there is nothing to route to,
-- so the window gets out of the way and comes back when you leave.
--
-- IsInInstance covers every instanced space, which avoids enumerating types
-- and guessing what a delve reports.
--
-- Opening or closing it yourself always wins: a manual action clears the
-- auto-hidden flag, so the addon will not undo a decision you just made.
--------------------------------------------------------------------------

local autoHidden    = false
local wasInInstance = false

local function EvaluateInstanceState()
	if not frame then return end
	if not ns.db.window.hideInInstances then return end

	local inInstance = IsInInstance() and true or false
	if inInstance == wasInInstance then return end
	wasInInstance = inInstance

	if inInstance then
		if frame:IsShown() then
			autoHidden = true
			frame:Hide()
			-- Hiding records "closed"; the instance is the reason, not a
			-- choice, so the remembered state stays open.
			ns.db.window.shown = true
		end
	elseif autoHidden then
		autoHidden = false
		UI:Show()
	end
end

function UI:Show()
	self:Build()
	autoHidden = false   -- you asked for it; do not second-guess later
	frame:Show()
	self:SyncFilters()
	ns:Fire("REQUEST_SCAN")
	self:Refresh()
end

function UI:Toggle()
	self:Build()
	if frame:IsShown() then
		autoHidden = false   -- closed on purpose; stay closed on the way out
		frame:Hide()
	else
		self:Show()
	end
end

--------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------

local function CreateMinimapButton()
	if not Minimap then return end

	local button = CreateFrame("Button", "SlootTrackerMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", -1, 1)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Map02")
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	local function Reposition()
		local angle = math.rad(ns.db.minimapAngle or 200)
		button:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
	end

	button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
		local mx, my = Minimap:GetCenter()
		local px, py = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		ns.db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
		Reposition()
	end) end)
	button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

	button:SetScript("OnClick", function(_, click)
		if click == "RightButton" then
			ns:Fire("OPEN_CONFIG")
		else
			UI:Toggle()
		end
	end)

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Sloot Tracker")
		GameTooltip:AddLine("Left-click: open the list", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	Reposition()
	ns.minimapButton = button
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	UI:Build()
	CreateMinimapButton()

	-- Open on login when asked to, otherwise reopen only if it was open when
	-- you logged out or reloaded.
	if frame and (ns.db.window.openOnLogin or frame.restoreShown) then
		UI:Show()
	end

	-- Other addons position frames on their own schedule, and whoever runs last
	-- wins. Rather than guess who moved ours, put it back once the dust has
	-- settled. Twice, because layout managers can be late.
	C_Timer.After(2, function() UI:RestoreGeometry() end)
	C_Timer.After(6, function() UI:RestoreGeometry() end)
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	-- Slight delay: instance state is not settled the instant this fires.
	C_Timer.After(1, EvaluateInstanceState)
end)

ns:On("TOGGLE_WINDOW", function() UI:Toggle() end)
ns:On("SHOW_WINDOW", function() UI:Show() end)
ns:On("SCAN_COMPLETE", function() UI:Refresh() end)
ns:On("ENTRIES_REFRESHED", function() UI:Refresh() end)
ns:On("ZONE_CHANGED", function() UI:Refresh() end)
