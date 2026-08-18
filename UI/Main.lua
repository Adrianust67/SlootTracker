--[[--------------------------------------------------------------------------
	SlootTracker - UI/Main.lua

	The window: scope + reach selectors, category filters, the planned route
	strip, and the ranked list.

	The list is a hand-rolled recycling scroller rather than a ScrollBox. It
	only ever creates as many row frames as fit on screen, and it survives
	template churn between patches.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local ROW_HEIGHT     = 32
local LIST_TOP_INSET = 168
local LIST_BOTTOM    = 30

local CATEGORY_COLORS = {
	achievements = { 0.95, 0.80, 0.20 },
	exploration  = { 0.45, 0.85, 0.55 },
	quests       = { 0.40, 0.70, 1.00 },
	treasures    = { 1.00, 0.55, 0.25 },
	mounts       = { 0.85, 0.45, 0.95 },
	toys         = { 0.40, 0.90, 0.90 },
	pets         = { 0.70, 0.90, 0.40 },
	transmogsets = { 0.90, 0.60, 0.70 },
	heirlooms    = { 0.60, 0.75, 0.95 },
	titles       = { 0.80, 0.80, 0.80 },
}

local FILTER_ORDER = {
	{ key = "quests",       label = "Quests" },
	{ key = "achievements", label = "Achievements" },
	{ key = "exploration",  label = "Exploration" },
	{ key = "treasures",    label = "Treasures" },
	{ key = "mounts",       label = "Mounts" },
	{ key = "toys",         label = "Toys" },
	{ key = "pets",         label = "Pets" },
	{ key = "transmogsets", label = "Transmog" },
	{ key = "heirlooms",    label = "Heirlooms" },
	{ key = "titles",       label = "Titles" },
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

local function FormatDistance(entry)
	if entry.distance then
		if entry.distance < 1000 then
			return ("%d yd"):format(entry.distance)
		end
		return ("%.1f k"):format(entry.distance / 1000)
	end
	return nil
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
-- Filtering / searching the scored list
--------------------------------------------------------------------------

local searchText = ""

local function RebuildDisplayed()
	wipe(displayed)
	local ignored = ns.db.ignored or {}
	local needle = searchText ~= "" and searchText:lower() or nil

	for _, entry in ipairs(ns.Priority.entries) do
		local ok = not ignored[entry.key]
		if ok and needle then
			local hay = ((entry.name or "") .. " " .. (entry.zoneName or "") .. " " .. (entry.detail or "")):lower()
			ok = hay:find(needle, 1, true) ~= nil
		end
		if ok then table.insert(displayed, entry) end
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

	-- Why is this ranked here?
	local p = entry.scoreParts
	if p and ns.db.debug then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Score", ("%.0f"):format(entry.score or 0), 0.6, 0.6, 0.6, 1, 0.82, 0)
		GameTooltip:AddDoubleLine("  weight x proximity",
			("%.2f x %.2f"):format(p.weight, p.proximity), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  progress x urgency",
			("%.2f x %.2f"):format(p.progress, p.urgency), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
		GameTooltip:AddDoubleLine("  points",
			("%.2f"):format(p.points or 1), 0.5, 0.5, 0.5, 0.9, 0.9, 0.9)
	end

	GameTooltip:AddLine(" ")
	if entry.x and entry.y then
		GameTooltip:AddLine("Left-click: set waypoint", 0.4, 0.8, 0.4)
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
	elseif entry.module == "quests" and entry.questID then
		if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
			ns.Try(C_SuperTrack.SetSuperTrackedQuestID, entry.questID)
		end
		ns.Try(C_QuestLog.SetSelectedQuest, entry.questID)
		if QuestMapFrame_OpenToQuestDetails then
			ns.Try(QuestMapFrame_OpenToQuestDetails, entry.questID)
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

		if entry.x and entry.y then
			root:CreateButton("Set waypoint", function()
				ns.Location:SetWaypoint(entry.mapID, entry.x, entry.y, entry.name)
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
	row:SetHeight(ROW_HEIGHT)
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

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.rank, "TOPRIGHT", 6, 1)
	row.name:SetJustifyH("LEFT")
	row.name:SetWidth(300)

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWidth(300)

	row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.zone:SetPoint("RIGHT", -90, 6)
	row.zone:SetJustifyH("RIGHT")
	row.zone:SetWidth(160)

	row.dist = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.dist:SetPoint("RIGHT", -90, -6)
	row.dist:SetJustifyH("RIGHT")
	row.dist:SetWidth(160)

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
		if entry.x and entry.y then
			ns.Location:SetWaypoint(entry.mapID, entry.x, entry.y, entry.name)
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
	row.detail:SetText(entry.detail or "")

	row.zone:SetText(entry.zoneName or "")
	local dist = FormatDistance(entry)
	if entry.tier == "here" and not dist then
		row.dist:SetText("|cff40ff40this zone|r")
	else
		row.dist:SetText(dist or (entry.tier == "continent" and "this continent" or ""))
	end

	if entry.have and entry.need and entry.need > 1 then
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

local function LayoutRows()
	local height = frame:GetHeight() - LIST_TOP_INSET - LIST_BOTTOM
	visibleRows = math.max(1, math.floor(height / ROW_HEIGHT))

	for i = 1, visibleRows do
		if not rows[i] then rows[i] = CreateRow(frame.list, i) end
		local row = rows[i]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.list, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
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
	if frame.SetResizeBounds then frame:SetResizeBounds(620, 380) end

	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 28,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		})
	end

	tinsert(UISpecialFrames, "SlootTrackerFrame")

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

	frame.zoneLabel = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.zoneLabel:SetPoint("LEFT", frame.title, "RIGHT", 10, 0)

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

	local SCOPE_LABEL = {
		auto      = "Scope: Per category",
		character = "Scope: This character",
		account   = "Scope: Entire account",
	}
	frame.scope = CreateSelector(frame, 170,
		function() return SCOPE_LABEL[ns.db.scope] or "Scope" end,
		function(root, done)
			root:CreateTitle("Track completion for")
			root:CreateButton("Per category (recommended)", function() ns.db.scope = "auto"; done() end)
			root:CreateButton("This character",  function() ns.db.scope = "character"; done() end)
			root:CreateButton("Entire account",  function() ns.db.scope = "account";   done() end)
			root:CreateDivider()
			root:CreateTitle("Per category")
			for _, cat in ipairs({ "achievements", "exploration", "quests" }) do
				local current = ns:ScopeFor(cat)
				root:CreateButton(("%s: %s"):format(cat, current), function()
					ns.db.categoryScope[cat] = (current == "account") and "character" or "account"
					ns.db.scope = "auto"
					done()
				end)
			end
		end,
		function()
			ns.db.scope = (ns.db.scope == "auto" and "character")
			           or (ns.db.scope == "character" and "account") or "auto"
		end)
	frame.scope:SetPoint("TOPLEFT", 16, -38)

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
	frame.reach:SetPoint("LEFT", frame.scope, "RIGHT", 6, 0)

	local search, templated = ns.SafeFrame("EditBox", nil, frame, "SearchBoxTemplate")
	search:SetSize(160, 22)
	search:SetPoint("LEFT", frame.reach, "RIGHT", 8, 0)
	search:SetAutoFocus(false)
	if not templated then
		-- Plain edit box fallback: give it a readable background and border.
		search:SetFontObject("ChatFontNormal")
		search:SetTextInsets(6, 6, 0, 0)
		local bg = search:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.5)
		search:SetScript("OnEscapePressed", search.ClearFocus)
	end
	search:SetScript("OnTextChanged", function(self, userInput)
		if templated and SearchBoxTemplate_OnTextChanged then
			SearchBoxTemplate_OnTextChanged(self, userInput)
		end
		searchText = self:GetText() or ""
		RebuildDisplayed()
		UpdateScroll()
	end)
	frame.search = search

	local config = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	config:SetSize(80, 22)
	config:SetPoint("TOPRIGHT", -16, -38)
	config:SetText("Settings")
	config:SetScript("OnClick", function() ns:Fire("OPEN_CONFIG") end)

	local rescan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	rescan:SetSize(80, 22)
	rescan:SetPoint("RIGHT", config, "LEFT", -4, 0)
	rescan:SetText("Rescan")
	rescan:SetScript("OnClick", function() ns:Fire("REQUEST_SCAN", true) end)

	--------------------------------------------------------------------
	-- Category filter checkboxes (two rows of five)
	--------------------------------------------------------------------

	frame.filterButtons = {}
	for i, def in ipairs(FILTER_ORDER) do
		local col = (i - 1) % 5
		local rowIdx = math.floor((i - 1) / 5)

		local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		check:SetSize(22, 22)
		check:SetPoint("TOPLEFT", 16 + col * 152, -68 - rowIdx * 22)
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
	list:SetPoint("TOPLEFT", 14, -LIST_TOP_INSET)
	list:SetPoint("BOTTOMRIGHT", -30, LIST_BOTTOM)
	frame.list = list

	slider = ns.CreateVerticalScrollBar(frame)
	slider:SetPoint("TOPRIGHT", -14, -LIST_TOP_INSET)
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

	frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 16, 12)
	frame.footer:SetJustifyH("LEFT")

	frame.warning = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.warning:SetPoint("BOTTOMRIGHT", -30, 12)
	frame.warning:SetJustifyH("RIGHT")

	frame:SetScript("OnSizeChanged", function() LayoutRows() end)
	frame:Hide()

	self:SyncFilters()
	LayoutRows()
	return frame
end

--------------------------------------------------------------------------
-- Public refresh entry points
--------------------------------------------------------------------------

function UI:SyncFilters()
	if not frame then return end
	for key, check in pairs(frame.filterButtons) do
		check:SetChecked(ns.db.filters[key] and true or false)
	end
	if frame.scope then frame.scope:Sync() end
	if frame.reach then frame.reach:Sync() end
end

function UI:Refresh()
	if not frame or not frame:IsShown() then return end

	local loc = ns.Location:Get()
	frame.zoneLabel:SetText(("|cffffd100%s|r%s"):format(
		loc.zoneName or "?",
		loc.subZone ~= "" and (" - " .. loc.subZone) or ""))

	RebuildDisplayed()
	UpdateScroll()
	UpdateRoute()

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
	local pointsText = ""
	if (ns.Priority.pointsAvailable or 0) > 0 then
		pointsText = ("  |  |cffffd100%d achievement points in reach|r"):format(ns.Priority.pointsAvailable)
	end
	frame.footer:SetText(("%d shown  |  %s%s"):format(#displayed, table.concat(parts, "  "), pointsText))

	if ns.Roster:AccountDataIsThin() then
		frame.warning:SetText("|cffff8040Account scope: only 1 character recorded so far|r")
	elseif ns.Priority.scanning then
		frame.warning:SetText("|cff888888scanning...|r")
	else
		frame.warning:SetText(("|cff888888%d characters recorded|r"):format(ns.Roster:CharacterCount()))
	end
end

function UI:Toggle()
	self:Build()
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
		self:SyncFilters()
		ns:Fire("REQUEST_SCAN")
		self:Refresh()
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
	if ns.db.hideMinimapButton then button:Hide() end
	ns.minimapButton = button
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	UI:Build()
	CreateMinimapButton()
end)

ns:On("TOGGLE_WINDOW", function() UI:Toggle() end)
ns:On("SCAN_COMPLETE", function() UI:Refresh() end)
ns:On("ENTRIES_REFRESHED", function() UI:Refresh() end)
ns:On("ZONE_CHANGED", function() UI:Refresh() end)
