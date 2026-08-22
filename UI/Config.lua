--[[--------------------------------------------------------------------------
	SlootTracker - UI/Config.lua

	Settings panel. Registered with the modern Settings API where available,
	falling back to the old InterfaceOptions registry.

	The panel is a plain canvas with a scroll child, because the option set is
	heterogeneous (checkboxes, sliders, a character roster) and does not map
	cleanly onto the declarative Settings controls.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Config = {}
ns.Config = Config

local PANEL_WIDTH = 620

--------------------------------------------------------------------------
-- Widget factory
--------------------------------------------------------------------------

local function MakeHeader(parent, text, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	fs:SetPoint("TOPLEFT", 16, y)
	fs:SetText(text)
	fs:SetTextColor(0.36, 0.75, 0.96)

	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetPoint("TOPLEFT", 16, y - 20)
	line:SetSize(PANEL_WIDTH - 60, 1)
	line:SetColorTexture(1, 1, 1, 0.15)

	return y - 34
end

local function MakeCheck(parent, label, tooltip, y, get, set, indent)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetPoint("TOPLEFT", 18 + (indent or 0), y)
	check:SetSize(24, 24)

	local fs = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", check, "RIGHT", 2, 0)
	fs:SetText(label)

	check:SetChecked(get())
	check:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
		ns:Fire("REQUEST_SCAN", true)
	end)

	if tooltip then
		check:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		check:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	parent.controls = parent.controls or {}
	table.insert(parent.controls, function() check:SetChecked(get()) end)
	return y - 26
end

local function MakeSlider(parent, label, tooltip, y, minV, maxV, step, get, set, format)
	local slider = ns.CreateSlider(parent, 240, minV, maxV, step)
	slider:SetPoint("TOPLEFT", 24, y - 12)
	slider:SetValue(get())

	local low = slider:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
	low:SetText(tostring(minV))

	local high = slider:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
	high:SetText(tostring(maxV))

	local title = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)

	local function Sync(value)
		title:SetText((format or "%s: %s"):format(label, ns.Round(value, 2)))
	end
	Sync(get())

	slider:SetScript("OnValueChanged", function(_, value)
		if step >= 1 then value = math.floor(value + 0.5) end
		set(value)
		Sync(value)
		ns:Fire("REQUEST_SCAN", true)
	end)

	if tooltip then
		slider:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		slider:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	parent.controls = parent.controls or {}
	table.insert(parent.controls, function() slider:SetValue(get()); Sync(get()) end)
	return y - 54
end

local function MakeButton(parent, label, y, x, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetPoint("TOPLEFT", x or 24, y)
	button:SetSize(width or 140, 22)
	button:SetText(label)
	button:SetScript("OnClick", onClick)
	return button
end

--------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------

function Config:Build()
	if self.panel then return self.panel end

	local panel = CreateFrame("Frame", "SlootTrackerConfigPanel")
	panel.name = "Sloot Tracker"
	self.panel = panel

	local scroll, templated = ns.SafeFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(PANEL_WIDTH, 1600)
	content.controls = {}   -- sync callbacks, populated by the widget helpers
	scroll:SetScrollChild(content)

	if not templated then
		-- No scroll template: drive the scroll frame from the mouse wheel and
		-- a hand-built bar, so the panel is still usable.
		local bar = ns.CreateVerticalScrollBar(panel)
		bar:SetPoint("TOPRIGHT", -8, -8)
		bar:SetPoint("BOTTOMRIGHT", -8, 8)
		bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
		scroll.zcBar = bar

		local function SyncRange()
			local range = math.max(0, content:GetHeight() - scroll:GetHeight())
			bar:SetMinMaxValues(0, range)
			bar:SetShown(range > 0)
		end
		scroll:SetScript("OnSizeChanged", SyncRange)
		scroll:SetScript("OnShow", SyncRange)
	end

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = math.max(0, content:GetHeight() - self:GetHeight())
		local target = math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40))
		self:SetVerticalScroll(target)
		if self.zcBar then self.zcBar:SetValue(target) end
	end)

	local y = -8

	----------------------------------------------------------------
	y = MakeHeader(content, "Scope", y)

	local scopeNote = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	scopeNote:SetPoint("TOPLEFT", 24, y)
	scopeNote:SetWidth(PANEL_WIDTH - 80)
	scopeNote:SetJustifyH("LEFT")
	scopeNote:SetText("Mounts, toys, pets, transmog, heirlooms and decor are stored account-wide "
		.. "by the game and are always tracked that way. These two are the only ones where the "
		.. "choice is real.")
	y = y - 34

	y = MakeCheck(content, "Achievements: track per character",
		"On: what THIS character still has left.\n"
		.. "Off: what the account still has left.\n\n"
		.. "Achievement credit is account-wide, but the game records which character earned "
		.. "each one, so both answers are available.",
		y,
		function() return ns:ScopeFor("achievements") == "character" end,
		function(v)
			ns.db.categoryScope.achievements = v and "character" or "account"
			ns.db.scope = "auto"
		end)

	y = MakeCheck(content, "Exploration: track per character",
		"On: subzones THIS character has never walked into, even if an alt found them.\n"
		.. "Off: subzones nobody on the account has found.",
		y,
		function() return ns:ScopeFor("exploration") == "character" end,
		function(v)
			ns.db.categoryScope.exploration = v and "character" or "account"
			ns.db.scope = "auto"
		end)

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Achievements", y)

	y = MakeCheck(content, "Rank by achievement points earned per remaining step",
		"Pushes high-value achievements up the list, but divides by how much work is left - "
		.. "so a 10-point achievement one criterion from done outranks a 25-point one needing "
		.. "forty more kills. This is the setting that makes the list chase achievement score.",
		y,
		function() return ns.db.achievements.prioritiseByPoints end,
		function(v) ns.db.achievements.prioritiseByPoints = v end)

	y = MakeSlider(content, "How hard points pull",
		"0 ignores points entirely; 2 makes them dominate everything except distance.",
		y, 0, 2, 0.1,
		function() return ns.db.achievements.pointsWeight end,
		function(v) ns.db.achievements.pointsWeight = v end,
		"%s: %s")

	y = MakeSlider(content, "Ignore achievements more than N steps away",
		"0 shows everything.\n\n"
		.. "A step is one thing still between you and the achievement. For a meta - "
		.. "an achievement earned by completing other achievements - each unfinished "
		.. "prerequisite counts as a step, including ones buried deeper. Set this to "
		.. "3 or so to drop the ones you cannot realistically act on today.",
		y, 0, 20, 1,
		function() return ns.db.achievements.maxSteps end,
		function(v) ns.db.achievements.maxSteps = v end,
		"%s: %s")

	y = MakeCheck(content, "Hide Feats of Strength", nil, y,
		function() return ns.db.achievements.hideFeatsOfStrength end,
		function(v) ns.db.achievements.hideFeatsOfStrength = v end)

	y = MakeCheck(content, "Hide legacy achievements",
		"Legacy achievements can no longer be earned.", y,
		function() return ns.db.achievements.hideLegacy end,
		function(v) ns.db.achievements.hideLegacy = v end)

	y = MakeCheck(content, "Show achievements earned by other characters",
		"Character scope only. Lists achievements your account already has but THIS character never personally earned.",
		y,
		function() return ns.db.achievements.includeEarnedByAlts end,
		function(v) ns.db.achievements.includeEarnedByAlts = v end)

	y = MakeCheck(content, "Only show achievements that are already part-finished", nil, y,
		function() return ns.db.achievements.onlyNearlyDone end,
		function(v) ns.db.achievements.onlyNearlyDone = v end)

	y = MakeSlider(content, "Minimum progress",
		"Used by the option above.", y, 0, 0.9, 0.05,
		function() return ns.db.achievements.nearlyDoneThreshold end,
		function(v) ns.db.achievements.nearlyDoneThreshold = v end,
		"%s: %s")

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Collections", y)

	y = MakeCheck(content, "Only show collectibles we can tie to a location",
		"Recommended. Turn this off to see every missing collectible, including ones with no known source zone "
		.. "(these only appear at 'Everywhere' reach).",
		y,
		function() return ns.db.collections.requireZoneMatch end,
		function(v) ns.db.collections.requireZoneMatch = v end)

	y = MakeCheck(content, "Hide unobtainable sources",
		"Hides promotional, trading-card and in-game-shop collectibles you cannot go and earn.",
		y,
		function() return ns.db.collections.hideUnobtainable end,
		function(v) ns.db.collections.hideUnobtainable = v end)

	y = MakeCheck(content, "Hide collectibles this character cannot obtain",
		"Collections are always tracked account-wide - this is only about routing. "
		.. "On: hide the wrong-faction and wrong-class ones you cannot walk over and get right now. "
		.. "Off: show everything the account is missing, including items only an alt could collect.",
		y,
		function() return ns.db.collections.hideUnusable end,
		function(v) ns.db.collections.hideUnusable = v end)

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Route planner", y)

	y = MakeCheck(content, "Plan a route through this zone",
		"Orders nearby objectives that have map coordinates into a nearest-first path, weighted by their priority.",
		y,
		function() return ns.db.route.enabled end,
		function(v) ns.db.route.enabled = v end)

	y = MakeSlider(content, "Route length", "How many stops to plan ahead.", y, 3, 20, 1,
		function() return ns.db.route.size end,
		function(v) ns.db.route.size = v end,
		"%s: %s stops")

	y = MakeCheck(content, "Automatically set a waypoint on the first stop",
		"Uses TomTom when installed, otherwise the built-in map pin.", y,
		function() return ns.db.route.autoPoint end,
		function(v) ns.db.route.autoPoint = v end)

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Nearby guild members", y)

	local radarNote = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	radarNote:SetPoint("TOPLEFT", 24, y)
	radarNote:SetWidth(PANEL_WIDTH - 80)
	radarNote:SetJustifyH("LEFT")
	radarNote:SetText("Spots guild members near you and announces it. Announcing to a real chat "
		.. "channel sends actual messages from your character - keep it private unless you mean it.")
	y = y - 34

	y = MakeCheck(content, "Detect nearby guild members", nil, y,
		function() return ns.db.guildRadar.enabled end,
		function(v) ns.db.guildRadar.enabled = v end)

	-- Detection mode
	local modeButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	modeButton:SetPoint("TOPLEFT", 28, y)
	modeButton:SetSize(240, 22)
	local MODE_LABEL = {
		zone  = "Detect: anywhere in my zone",
		close = "Detect: within nameplate range",
		both  = "Detect: zone and nameplate range",
	}
	local function SyncMode() modeButton:SetText(MODE_LABEL[ns.db.guildRadar.mode] or "Detect") end
	modeButton:SetScript("OnClick", function()
		local order = { zone = "close", close = "both", both = "zone" }
		ns.db.guildRadar.mode = order[ns.db.guildRadar.mode] or "both"
		SyncMode()
		if ns.GuildRadar:NameplateModeBlocked() then ns.GuildRadar:ExplainNameplates() end
	end)
	SyncMode()
	table.insert(content.controls, SyncMode)
	y = y - 28

	-- Output channel
	local outButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	outButton:SetPoint("TOPLEFT", 28, y)
	outButton:SetSize(240, 22)
	local function SyncOut()
		outButton:SetText("Announce in: " .. ns.GuildRadar:OutputLabel(ns.db.guildRadar.output))
	end
	outButton:SetScript("OnClick", function(self)
		if MenuUtil and MenuUtil.CreateContextMenu then
			MenuUtil.CreateContextMenu(self, function(_, root)
				root:CreateTitle("Announce in")
				for _, def in ipairs(ns.GuildRadar.OUTPUTS) do
					root:CreateButton(def.label, function()
						ns.db.guildRadar.output = def.key
						SyncOut()
					end)
				end
			end)
		else
			local list = ns.GuildRadar.OUTPUTS
			local index = 1
			for i, def in ipairs(list) do
				if def.key == ns.db.guildRadar.output then index = i end
			end
			ns.db.guildRadar.output = list[(index % #list) + 1].key
			SyncOut()
		end
	end)
	SyncOut()
	table.insert(content.controls, SyncOut)

	local outWarning = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	outWarning:SetPoint("LEFT", outButton, "RIGHT", 8, 0)
	outWarning:SetText("|cffff8040sends real chat messages|r")
	outWarning:SetShown(ns.db.guildRadar.output ~= "self")
	table.insert(content.controls, function()
		outWarning:SetShown(ns.db.guildRadar.output ~= "self")
	end)
	y = y - 30

	local templateLabel = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	templateLabel:SetPoint("TOPLEFT", 28, y)
	templateLabel:SetText("Message")
	y = y - 18

	local templateBox, boxTemplated = ns.SafeFrame("EditBox", nil, content, "InputBoxTemplate")

	-- Set the font unconditionally. An EditBox with no font object holds its
	-- text perfectly and draws nothing at all - an empty-looking box with the
	-- value intact. Relying on the template to provide one is exactly the kind
	-- of assumption this UI has already broken twice.
	templateBox:SetFontObject("ChatFontNormal")
	templateBox:SetTextColor(1, 1, 1)
	templateBox:SetTextInsets(6, 6, 0, 0)

	if not boxTemplated then
		local boxBG = templateBox:CreateTexture(nil, "BACKGROUND")
		boxBG:SetAllPoints()
		boxBG:SetColorTexture(0, 0, 0, 0.5)
	end
	templateBox:SetPoint("TOPLEFT", 34, y)
	templateBox:SetSize(PANEL_WIDTH - 110, 22)
	templateBox:SetAutoFocus(false)
	templateBox:SetText(ns.db.guildRadar.template or "")
	-- Committing only on Enter meant typing a message and clicking away threw
	-- it silently away: the next panel refresh repainted the box from the
	-- database. Saving on focus loss as well is what people actually expect.
	local reverting = false

	local function CommitTemplate(self)
		if reverting then reverting = false return end

		local text = self:GetText() or ""
		if text == (ns.db.guildRadar.template or "") then return end

		ns.db.guildRadar.template = text
		ns:Print("guild radar message saved.")
		if not ns.GuildRadar:TemplateMentionsName() then
			ns.GuildRadar:ExplainTemplate()
		end
	end

	templateBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	templateBox:SetScript("OnEditFocusLost", CommitTemplate)
	templateBox:SetScript("OnEscapePressed", function(self)
		reverting = true
		self:SetText(ns.db.guildRadar.template or "")
		self:ClearFocus()
	end)

	table.insert(content.controls, function()
		-- Never repaint a box the player is typing in.
		if not templateBox:HasFocus() then
			templateBox:SetText(ns.db.guildRadar.template or "")
		end
	end)
	y = y - 24

	local tokenHelp = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	tokenHelp:SetPoint("TOPLEFT", 34, y)
	tokenHelp:SetWidth(PANEL_WIDTH - 90)
	tokenHelp:SetJustifyH("LEFT")
	tokenHelp:SetText("Tokens: %name% %zone% %count% %points% %how%   -   press Enter to save")
	y = y - 26

	y = MakeSlider(content, "Do not repeat the same person for",
		"Per-player cooldown, so one guildmate standing next to you does not repeat.",
		y, 60, 3600, 60,
		function() return ns.db.guildRadar.cooldown end,
		function(v) ns.db.guildRadar.cooldown = v end,
		"%s: %s seconds")

	y = MakeSlider(content, "Minimum gap between any two announcements",
		"A hard floor that applies across everyone, to stay well clear of the chat throttle.",
		y, 5, 300, 5,
		function() return ns.db.guildRadar.minInterval end,
		function(v) ns.db.guildRadar.minInterval = v end,
		"%s: %s seconds")

	y = MakeCheck(content, "Play a sound when one is detected", nil, y,
		function() return ns.db.guildRadar.sound end,
		function(v) ns.db.guildRadar.sound = v end)

	MakeButton(content, "Test now", y + 6, 24, 120, function()
		ns:Fire("GUILD_RADAR_CHECK", true)
	end)
	MakeButton(content, "Clear cooldowns", y + 6, 152, 150, function()
		ns:Fire("GUILD_RADAR_RESET")
		ns:Print("guild radar cooldowns cleared.")
	end)
	y = y - 28

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Priority weights", y)

	local weightNote = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	weightNote:SetPoint("TOPLEFT", 24, y)
	weightNote:SetWidth(PANEL_WIDTH - 80)
	weightNote:SetJustifyH("LEFT")
	weightNote:SetText("Multiplies each category's score. Distance still dominates - these decide ties "
		.. "and how hard the list pulls you toward one kind of content.")
	y = y - 30

	-- Kept in step with the main window's filter row; the categories themselves
	-- are toggled there, only their weighting lives here.
	local WEIGHT_CATS = {
		{ "achievements", "Achievements" },
		{ "exploration",  "Unexplored areas" },
		{ "treasures",    "Treasures and rares" },
		{ "mounts",       "Mounts" },
		{ "toys",         "Toys" },
		{ "pets",         "Battle pets" },
		{ "transmogsets", "Transmog sets" },
		{ "heirlooms",    "Heirlooms" },
		{ "titles",       "Titles" },
		{ "decor",        "Housing decor" },
	}

	for _, cat in ipairs(WEIGHT_CATS) do
		local key, label = cat[1], cat[2]
		y = MakeSlider(content, label, nil, y, 0, 3, 0.1,
			function() return ns.db.weights[key] or 1 end,
			function(v) ns.db.weights[key] = v end,
			"%s weight: %s")
	end

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "General", y)

	y = MakeCheck(content, "Rescan automatically when you change zone", nil, y,
		function() return ns.db.autoRescan end,
		function(v) ns.db.autoRescan = v end)

	y = MakeCheck(content, "Include PvP content",
		"Off hides everything tied to PvP across every category at once: PvP "
		.. "achievements, and any mount, toy, pet or decor whose source is honor, "
		.. "conquest, arenas, battlegrounds or rated play.\n\n"
		.. "Achievements are identified by their category, so that part is exact. "
		.. "Collectibles are identified from their source text, which is a very "
		.. "good guess but not a guarantee.",
		y,
		function() return ns.db.includePvP end,
		function(v) ns.db.includePvP = v end)

	y = MakeCheck(content, "Only list things with an exact location",
		"Anything we can place to a zone but not to a spot is already ranked far "
		.. "down the list. This drops it entirely.\n\n"
		.. "Strongest setting for \"show me what I can walk to right now\", but it "
		.. "hides most collectibles: the game rarely says where a mount or toy "
		.. "actually drops, only which zone.",
		y,
		function() return ns.db.requireExactLocation end,
		function(v) ns.db.requireExactLocation = v end)

	y = MakeCheck(content, "Get out of the way inside instances",
		"Closes the window when you enter a dungeon, raid, delve, scenario or "
		.. "battleground, and reopens it when you leave.\n\n"
		.. "Opening or closing it yourself always wins: if you reopen it inside an "
		.. "instance it stays open, and if you close it yourself it stays closed "
		.. "on the way out.",
		y,
		function() return ns.db.window.hideInInstances end,
		function(v) ns.db.window.hideInInstances = v end)

	y = MakeCheck(content, "Open the window when you log in",
		"On: the tracker opens automatically at login and after a reload.\n\n"
		.. "Off: it comes back only if it was open when you last logged out.",
		y,
		function() return ns.db.window.openOnLogin end,
		function(v) ns.db.window.openOnLogin = v end)

	y = MakeCheck(content, "Debug output", "Prints scan diagnostics and shows score breakdowns in tooltips.", y,
		function() return ns.db.debug end,
		function(v) ns.db.debug = v end)

	y = MakeSlider(content, "Maximum rows", "Caps how many results are kept after sorting.", y, 50, 1000, 50,
		function() return ns.db.maxRows end,
		function(v) ns.db.maxRows = v end,
		"%s: %s")

	----------------------------------------------------------------
	y = y - 8
	y = MakeHeader(content, "Recorded characters", y)

	content.rosterRows = {}
	content.rosterAnchor = y

	----------------------------------------------------------------
	local resetY = y - 220

	MakeButton(content, "Clear ignored entries", resetY, 24, 180, function()
		ns.db.ignored = {}
		ns:Print("ignore list cleared.")
		ns:Fire("REQUEST_SCAN", true)
	end)

	MakeButton(content, "Rebuild indexes", resetY, 212, 180, function()
		ns.db.cache = { build = ns.build }
		ns:Print("cache cleared, re-indexing...")
		for _, key in ipairs(ns.providerOrder) do
			local p = ns.providers[key]
			if p.Prepare then ns.Try(p.Prepare, p) end
		end
		ns:Fire("REQUEST_SCAN", true)
	end)

	MakeButton(content, "Restore defaults", resetY, 400, 180, function()
		local roster, cache = ns.db.roster, ns.db.cache
		wipe(ns.db)
		ns.CopyDefaults(ns.defaults, ns.db)
		ns.db.roster, ns.db.cache = roster, cache
		Config:Refresh()
		ns.UI:SyncFilters()
		ns:Fire("REQUEST_SCAN", true)
		ns:Print("settings restored to defaults.")
	end)

	content:SetHeight(math.abs(resetY) + 80)
	self.content = content

	panel:SetScript("OnShow", function() Config:Refresh() end)
	return panel
end

--------------------------------------------------------------------------
-- Roster list
--------------------------------------------------------------------------

function Config:RefreshRoster()
	local content = self.content
	if not content then return end

	for _, row in ipairs(content.rosterRows) do row:Hide() end

	local chars = ns.Roster:GetCharacters()
	for i, char in ipairs(chars) do
		if i > 8 then break end

		local row = content.rosterRows[i]
		if not row then
			row = CreateFrame("Frame", nil, content)
			row:SetSize(PANEL_WIDTH - 60, 20)
			row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.text:SetPoint("LEFT", 0, 0)
			row.forget = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.forget:SetSize(70, 18)
			row.forget:SetPoint("LEFT", 380, 0)
			row.forget:SetText("Forget")
			content.rosterRows[i] = row
		end

		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 24, content.rosterAnchor - (i - 1) * 22)

		local color = char.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.class]
		local nameText = char.name or char.key
		if color then nameText = ("|c%s%s|r"):format(color.colorStr or "ffffffff", nameText) end

		row.text:SetText(("%s%s  |cff888888level %s - %d quests recorded|r"):format(
			nameText,
			char.isMe and " |cff40ff40(you)|r" or "",
			tostring(char.level or "?"),
			char.questCount or 0))

		row.forget:SetShown(not char.isMe)
		row.forget:SetScript("OnClick", function()
			ns.Roster:Forget(char.key)
			Config:RefreshRoster()
			ns:Fire("REQUEST_SCAN", true)
		end)
		row:Show()
	end

	if #chars == 0 then
		return
	end
end

function Config:Refresh()
	local content = self.content
	if not content then return end
	for _, sync in ipairs(content.controls or {}) do pcall(sync) end
	self:RefreshRoster()
end

--------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------

function Config:Register()
	local panel = self:Build()

	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, "Sloot Tracker")
		Settings.RegisterAddOnCategory(category)
		self.category = category
		self.categoryID = category:GetID()
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

function Config:Open()
	if not self.panel then self:Register() end

	if Settings and Settings.OpenToCategory and self.categoryID then
		Settings.OpenToCategory(self.categoryID)
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(self.panel)
		InterfaceOptionsFrame_OpenToCategory(self.panel) -- old client quirk
	else
		ns:Print("could not open the settings panel; use /zc commands instead.")
	end
end

ns:On("PLAYER_READY", function() Config:Register() end)
ns:On("OPEN_CONFIG", function() Config:Open() end)
