--[[--------------------------------------------------------------------------
	SlootTracker - Core/Init.lua

	Namespace, saved variables, event bus, chunked task runner, slash commands.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
_G.SlootTracker = ns

ns.ADDON = ADDON
local function Meta(field, fallback)
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		local value = C_AddOns.GetAddOnMetadata(ADDON, field)
		if value and value ~= "" then return value end
	end
	return fallback
end

ns.version = Meta("Version", "1.0.0")
ns.author  = Meta("Author", "BadHeffer")
ns.build = select(4, GetBuildInfo())

--------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------

ns.defaults = {
	-- Master scope switch.
	--   "auto"      = use categoryScope below (the sane default)
	--   "character" = force everything to this character's perspective
	--   "account"   = force everything to the account's perspective
	scope = "auto",

	-- Scope per content type. Defaults follow how the game actually stores
	-- each thing: achievement credit and exploration are meaningful per
	-- character, everything else is genuinely account-wide.
	categoryScope = {
		achievements = "character",
		exploration  = "character",
	},

	window = {
		point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
		width = 820, height = 560,
		-- Remember whether it was open, so it comes back as you left it.
		shown = false,
		-- Always open on login, regardless of how you left it.
		openOnLogin = true,
		-- Step aside inside dungeons, raids, delves and battlegrounds, and come
		-- back on the way out.
		hideInInstances = true,
	},

	-- Which content categories feed the list.
	filters = {
		achievements = true,
		exploration  = true,
		treasures    = true,
		mounts       = true,
		toys         = true,
		pets         = true,
		transmogsets = false,
		heirlooms    = false,
		titles       = false,
		decor        = true,
	},

	-- How far out we are willing to look.
	--   zone      = current zone only
	--   continent = current zone + everything on this continent
	--   world     = everything, anywhere (slow, mostly useful for planning)
	reach = "continent",

	achievements = {
		hideStatistics      = true,
		hideFeatsOfStrength = false,
		hideLegacy          = false,
		-- Character scope only: also list achievements the account already has
		-- but THIS character never personally earned.
		includeEarnedByAlts = false,
		-- Rank by points earned per remaining step, not just by proximity.
		prioritiseByPoints  = true,
		pointsWeight        = 1.0,
		-- Hide achievements more than N steps from completion (0 = no limit).
		-- For a meta, a "step" is a whole prerequisite achievement.
		maxSteps            = 0,
		onlyNearlyDone      = false,
		nearlyDoneThreshold = 0.34,   -- when onlyNearlyDone, require >= this progress
		showCriteria        = true,   -- surface the specific missing criteria
	},

	collections = {
		hideUnobtainable = true,
		requireZoneMatch = true,      -- hide collectibles we could not tie to a zone
		-- Collection state is account-wide regardless; this is purely a
		-- "can this character walk over and get it" filter.
		hideUnusable     = true,
	},

	treasures = {
		areaPOIs  = true,
		vignettes = true,
	},

	-- Category weights feeding the priority score.
	weights = {
		achievements = 1.0,
		exploration  = 1.4,
		treasures    = 1.1,
		mounts       = 1.5,
		toys         = 1.2,
		pets         = 0.9,
		transmogsets = 0.7,
		heirlooms    = 0.5,
		titles       = 0.5,
		decor        = 1.0,
	},

	route = {
		enabled   = true,
		size      = 8,       -- how many stops the nearest-neighbour route plans
		autoPoint = false,   -- auto-set a waypoint on the top route stop
	},

	-- Nearby guild member detection.
	guildRadar = {
		enabled     = false,
		mode        = "both",   -- "zone" | "close" | "both"
		-- Default output stays inside your own client. Broadcasting to a real
		-- chat channel is opt-in on purpose: automated messages to GUILD/SAY
		-- are how people get muted.
		output      = "self",
		template    = "%name% is %how% - %count% things to do in %zone%",
		cooldown    = 600,      -- per player, seconds
		minInterval = 20,       -- global floor between any two announcements
		sound       = false,
	},

	-- One global switch for everyone who does not PvP. Off hides PvP
	-- achievements and any collectible whose source is honor, conquest,
	-- arenas, battlegrounds or rated play.
	includePvP  = true,

	maxRows     = 300,
	autoRescan  = true,      -- rescan when the player changes zone
	debug       = false,

	minimapAngle      = 200,
	ignored           = {},   -- [entryKey] = true
}

--------------------------------------------------------------------------
-- Small utilities
--------------------------------------------------------------------------

local function CopyDefaults(src, dst)
	if type(dst) ~= "table" then dst = {} end
	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = CopyDefaults(v, rawget(dst, k))
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end
ns.CopyDefaults = CopyDefaults

function ns:Print(...)
	print("|cff5bc0f5Sloot Tracker|r:", ...)
end

function ns:Debug(...)
	if self.db and self.db.debug then
		print("|cff888888ST|r:", ...)
	end
end

-- Safe call: modules poke a lot of API surface that shifts between patches.
-- Must forward every return value - GetAchievementInfo alone returns 15 -
-- including embedded nils, so the results are tail-forwarded, not packed.
local function TryResult(ok, ...)
	if not ok then
		if ns.db and ns.db.debug then print("|cffff5555ST error|r:", (...)) end
		return nil
	end
	return ...
end

function ns.Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	return TryResult(pcall(fn, ...))
end

-- ns.Try cannot tell "the call failed" from "the call succeeded and returned
-- nil", because both come back as nil. Plenty of API functions return nothing
-- at all - SendChatMessage among them - so testing ns.Try's result for nil
-- reports every successful call as a failure. Use this when the outcome, not
-- the return value, is what matters.
--
-- Returns: ok (boolean), followed by whatever the function returned.
function ns.TryOk(fn, ...)
	if type(fn) ~= "function" then return false end
	return pcall(fn, ...)
end

function ns.Round(v, places)
	local m = 10 ^ (places or 0)
	return math.floor(v * m + 0.5) / m
end

--------------------------------------------------------------------------
-- Scope resolution
--
-- Every module asks this instead of reading db.scope directly, so the master
-- switch and the per-category defaults stay in one place.
--
-- Categories with no per-category entry resolve to "account", which is
-- correct for collections: the game stores them account-wide and there is no
-- per-character notion of owning a mount.
--------------------------------------------------------------------------

function ns:ScopeFor(category)
	local master = self.db and self.db.scope or "auto"
	if master == "character" or master == "account" then return master end

	local per = self.db.categoryScope and self.db.categoryScope[category]
	return per or "account"
end

function ns:IsAccountScope(category)
	return self:ScopeFor(category) == "account"
end

--------------------------------------------------------------------------
-- UI primitives
--
-- Blizzard retired a pile of XML templates during the 10.x/11.x UI rework
-- (UIPanelScrollBarTemplate, OptionsSliderTemplate and friends). Anything
-- template-based is created defensively, and sliders are built by hand so
-- they cannot break on a future template removal.
--------------------------------------------------------------------------

function ns.SafeFrame(frameType, name, parent, template, ...)
	if template then
		local ok, f = pcall(CreateFrame, frameType, name, parent, template, ...)
		if ok and f then return f, true end
		ns:Debug("template unavailable:", template)
	end
	return CreateFrame(frameType, name, parent), false
end

-- Minimal horizontal slider with no template dependency.
-- Returns the slider; caller wires OnValueChanged.
function ns.CreateSlider(parent, width, minV, maxV, step)
	local slider = CreateFrame("Slider", nil, parent)
	slider:SetSize(width or 240, 16)
	slider:SetOrientation("HORIZONTAL")
	slider:SetHitRectInsets(0, 0, -6, -6)
	slider:SetMinMaxValues(minV or 0, maxV or 1)
	slider:SetValueStep(step or 1)
	slider:SetObeyStepOnDrag(true)
	slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

	local thumb = slider:GetThumbTexture()
	thumb:SetSize(20, 20)

	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("LEFT", 0, 0)
	track:SetPoint("RIGHT", 0, 0)
	track:SetHeight(5)
	track:SetColorTexture(0, 0, 0, 0.55)

	local edge = slider:CreateTexture(nil, "BORDER")
	edge:SetPoint("TOPLEFT", track, -1, 1)
	edge:SetPoint("BOTTOMRIGHT", track, 1, -1)
	edge:SetColorTexture(1, 1, 1, 0.10)

	return slider
end

-- Vertical scrollbar built the same way, used by the main list.
function ns.CreateVerticalScrollBar(parent)
	local bar = CreateFrame("Slider", nil, parent)
	bar:SetWidth(14)
	bar:SetOrientation("VERTICAL")
	bar:SetValueStep(1)
	bar:SetObeyStepOnDrag(true)
	bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")

	local thumb = bar:GetThumbTexture()
	thumb:SetSize(14, 26)
	thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)

	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("TOP", 0, 0)
	track:SetPoint("BOTTOM", 0, 0)
	track:SetWidth(5)
	track:SetColorTexture(0, 0, 0, 0.45)

	return bar
end

--------------------------------------------------------------------------
-- Callback registry (modules -> UI)
--------------------------------------------------------------------------

local callbacks = {}

function ns:On(message, fn)
	callbacks[message] = callbacks[message] or {}
	table.insert(callbacks[message], fn)
end

-- Errors used to go to ns:Debug, which prints nothing unless debug mode is on.
-- That turned a failure to build the window into a silently half-drawn frame
-- with no clue what went wrong. Real errors are now always reported, throttled
-- per site so a per-frame failure cannot flood the chat.
local reported = {}

function ns.ReportError(where, err)
	if reported[where] then return end
	reported[where] = true
	print(("|cffff5555Sloot Tracker error|r in %s: %s"):format(where, tostring(err)))
	print("|cff888888Please report this. Further errors here are suppressed.|r")
end

function ns:Fire(message, ...)
	local list = callbacks[message]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then ns.ReportError("callback " .. tostring(message), err) end
	end
end

--------------------------------------------------------------------------
-- Event bus
--------------------------------------------------------------------------

local frame = CreateFrame("Frame", "SlootTrackerEventFrame")
local handlers = {}

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], event, ...)
		if not ok then ns.ReportError("event " .. tostring(event), err) end
	end
end)

function ns:RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok = pcall(frame.RegisterEvent, frame, event)
		if not ok then
			ns:Debug("could not register event", event)
			handlers[event] = nil
			return
		end
	end
	table.insert(handlers[event], fn)
end

--------------------------------------------------------------------------
-- Chunked task runner
--
-- Scanning every achievement / mount / toy in one frame produces a visible
-- hitch. Tasks yield after a time budget and resume on the next frame.
--------------------------------------------------------------------------

local BUDGET = 0.008 -- seconds of work per frame
local tasks = {}
local runner = CreateFrame("Frame")
runner:Hide()

runner:SetScript("OnUpdate", function()
	local start = debugprofilestop()
	local i = 1
	while i <= #tasks do
		local task = tasks[i]
		local finished = false
		while (debugprofilestop() - start) < (BUDGET * 1000) do
			local ok, more = pcall(task.step)
			if not ok then
				ns:Debug("task error", task.name, more)
				finished = true
				break
			end
			if not more then
				finished = true
				break
			end
		end
		if finished then
			table.remove(tasks, i)
			if task.onDone then pcall(task.onDone) end
		else
			i = i + 1
		end
		if (debugprofilestop() - start) >= (BUDGET * 1000) then break end
	end
	if #tasks == 0 then runner:Hide() end
end)

-- ns:RunTask(name, stepFn, onDone)
--   stepFn returns true while there is more work to do.
function ns:RunTask(name, stepFn, onDone)
	for i = 1, #tasks do
		if tasks[i].name == name then return false end -- already queued
	end
	table.insert(tasks, { name = name, step = stepFn, onDone = onDone })
	runner:Show()
	return true
end

function ns:IsTaskRunning(name)
	for i = 1, #tasks do
		if tasks[i].name == name then return true end
	end
	return false
end

-- Convenience: turn an array into a chunked task.
function ns:RunOverList(name, list, perItem, onDone)
	local i = 0
	return self:RunTask(name, function()
		i = i + 1
		local item = list[i]
		if item == nil then return false end
		perItem(item, i)
		return i < #list
	end, onDone)
end

--------------------------------------------------------------------------
-- Provider registry
--
-- Every content module registers a provider. A provider returns a flat list
-- of entries; Priority.lua scores and sorts them.
--------------------------------------------------------------------------

ns.providers = {}
ns.providerOrder = {}

-- provider = {
--   key      = "achievements",
--   label    = "Achievements",
--   filters  = { "achievements" },        -- db.filters keys that enable it
--   Prepare  = function(self) end,        -- optional, one-time index build
--   Scan     = function(self, ctx) end,   -- returns array of entries
-- }
function ns:RegisterProvider(provider)
	self.providers[provider.key] = provider
	table.insert(self.providerOrder, provider.key)
end

function ns:ProviderEnabled(provider)
	local f = self.db and self.db.filters
	if not f then return false end
	for _, key in ipairs(provider.filters or { provider.key }) do
		if f[key] then return true end
	end
	return false
end

--------------------------------------------------------------------------
-- Saved variables / bootstrap
--------------------------------------------------------------------------

local function InitDB()
	_G.SlootTrackerDB  = CopyDefaults(ns.defaults, _G.SlootTrackerDB or {})
	_G.SlootTrackerCharDB = _G.SlootTrackerCharDB or {}

	ns.db     = _G.SlootTrackerDB
	ns.chardb = _G.SlootTrackerCharDB

	ns.db.cache = ns.db.cache or {}
	ns.db.roster = ns.db.roster or {}

	-- Blow away derived caches when the client build changes; achievement
	-- and map data shift between patches.
	--
	-- The schema number covers the other case: when an addon update changes
	-- what an index *contains*, a cache built by the old version is stale even
	-- though the client build is identical. Bump it whenever the shape of
	-- anything under db.cache changes.
	local CACHE_SCHEMA = 2
	if ns.db.cache.build ~= ns.build or ns.db.cache.schema ~= CACHE_SCHEMA then
		ns.db.cache = { build = ns.build, schema = CACHE_SCHEMA }
	end
end

ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	InitDB()
	ns.loaded = true
	ns:Fire("DB_READY")
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
	if not ns.loaded then InitDB() end

	ns.playerName  = UnitName("player")
	ns.playerRealm = GetRealmName()
	ns.playerKey   = ns.playerName .. " - " .. ns.playerRealm
	ns.playerFaction = UnitFactionGroup("player")

	ns:Fire("PLAYER_READY")

	C_Timer.After(3, function()
		for _, key in ipairs(ns.providerOrder) do
			local p = ns.providers[key]
			if p.Prepare then ns.Try(p.Prepare, p) end
		end
		ns:Fire("PROVIDERS_PREPARED")
	end)

	ns:Print(("v%s loaded. |cffffd100/zc|r to open, |cffffd100/zc help|r for commands.")
		:format(ns.version))
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_SLOOTTRACKER1 = "/sloot"
SLASH_SLOOTTRACKER2 = "/slt"
SLASH_SLOOTTRACKER3 = "/zc"

local function Usage()
	ns:Print("commands:")
	print("  |cffffd100/zc|r - toggle the window")
	print("  |cffffd100/zc scan|r - force a rescan")
	print("  |cffffd100/zc auto|r - scope per category (default)")
	print("  |cffffd100/zc char|r / |cffffd100/zc account|r - force one scope everywhere")
	print("  |cffffd100/sloot guild on|off|test|r - nearby guild member detection")
	print("  |cffffd100/sloot guild out self|guild|say|yell|party|emote|r - where it announces")
	print("  |cffffd100/zc config|r - open settings")
	print("  |cffffd100/zc reach zone|continent|world|r - how far to look")
	print("  |cffffd100/zc route|r - print the planned route for this zone")
	print("  |cffffd100/zc reset|r - wipe the derived cache and re-index")
	print("  |cffffd100/zc debug|r - toggle debug output")
end

SlashCmdList.SLOOTTRACKER = function(msg)
	-- Keep the original before lowercasing: commands that take free text (the
	-- guild radar message) must preserve the capitalisation you typed.
	local msgRaw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	msg = msgRaw:lower()
	local cmd, rest = msg:match("^(%S*)%s*(.*)$")

	if cmd == "" then
		ns:Fire("TOGGLE_WINDOW")
	elseif cmd == "scan" then
		ns:Fire("REQUEST_SCAN", true)
		ns:Print("rescanning...")
	elseif cmd == "char" or cmd == "character" then
		ns.db.scope = "character"
		ns:Print("scope: |cffffd100forced to this character|r")
		ns:Fire("SCOPE_CHANGED")
		ns:Fire("REQUEST_SCAN", true)
	elseif cmd == "account" then
		ns.db.scope = "account"
		ns:Print("scope: |cffffd100forced to the entire account|r")
		ns:Fire("SCOPE_CHANGED")
		ns:Fire("REQUEST_SCAN", true)
	elseif cmd == "auto" then
		ns.db.scope = "auto"
		ns:Print("scope: |cffffd100per category|r "
			.. "(achievements + exploration = character, collections = account)")
		ns:Fire("SCOPE_CHANGED")
		ns:Fire("REQUEST_SCAN", true)
	elseif cmd == "guild" then
		local sub, arg = rest:match("^(%S*)%s*(.*)$")
		if sub == "on" then
			ns.db.guildRadar.enabled = true
			ns:Print(("guild radar |cff40ff40on|r - announcing to |cffffd100%s|r"):format(
				ns.GuildRadar:OutputLabel(ns.db.guildRadar.output)))
			if ns.GuildRadar:NameplateModeBlocked() then ns.GuildRadar:ExplainNameplates() end
			if not ns.GuildRadar:TemplateMentionsName() then ns.GuildRadar:ExplainTemplate() end
		elseif sub == "off" then
			ns.db.guildRadar.enabled = false
			ns:Print("guild radar |cffff5555off|r")
		elseif sub == "test" then
			ns:Fire("GUILD_RADAR_CHECK", true)
		elseif sub == "reset" then
			ns:Fire("GUILD_RADAR_RESET")
			ns:Print("guild radar cooldowns cleared.")
		elseif sub == "out" or sub == "output" then
			local map = {
				self = "self", guild = "GUILD", say = "SAY",
				yell = "YELL", party = "PARTY", emote = "EMOTE",
			}
			local target = map[arg]
			if target then
				ns.db.guildRadar.output = target
				ns:Print(("guild radar announces to |cffffd100%s|r"):format(
					ns.GuildRadar:OutputLabel(target)))
				if target ~= "self" then
					ns:Print("|cffff8040heads up:|r this sends real chat messages. "
						.. "Keep it slow or people will notice.")
				end
			else
				ns:Print("use: self / guild / say / yell / party / emote")
			end
		elseif sub == "msg" or sub == "message" then
			-- Deliberately uses the raw slash text, not the lowercased command,
			-- so the message keeps the capitalisation you typed.
			local raw = (msgRaw or ""):match("^%s*%S+%s+%S+%s+(.*)$")
			if raw and raw ~= "" then
				ns.db.guildRadar.template = raw
				ns:Print("guild radar message set to:")
				print("  " .. raw)
				if not ns.GuildRadar:TemplateMentionsName() then
					ns.GuildRadar:ExplainTemplate()
				end
			else
				ns:Print("current message: " .. (ns.db.guildRadar.template or "(none)"))
				print("  set it with: |cffffd100/sloot guild msg <text>|r")
				print("  tokens: |cffffd100%name% %zone% %count% %points% %how%|r")
			end
		elseif sub == "mode" then
			if arg == "zone" or arg == "close" or arg == "both" then
				ns.db.guildRadar.mode = arg
				ns:Print(("guild radar mode |cffffd100%s|r"):format(arg))
				if ns.GuildRadar:NameplateModeBlocked() then ns.GuildRadar:ExplainNameplates() end
			else
				ns:Print("use: zone (same zone) / close (nameplate range) / both")
			end
		else
			ns:Print(("guild radar is %s, mode |cffffd100%s|r, announcing to |cffffd100%s|r."):format(
				ns.db.guildRadar.enabled and "|cff40ff40on|r" or "|cffff5555off|r",
				ns.db.guildRadar.mode,
				ns.GuildRadar:OutputLabel(ns.db.guildRadar.output)))
			print("  on / off / test / reset / msg <text> / mode <zone|close|both> / out <self|guild|say|yell|party|emote>")
		end
	elseif cmd == "config" or cmd == "options" then
		ns:Fire("OPEN_CONFIG")
	elseif cmd == "route" then
		ns:Fire("PRINT_ROUTE")
	elseif cmd == "reset" then
		ns.db.cache = { build = ns.build }
		ns:Print("cache cleared, re-indexing...")
		for _, key in ipairs(ns.providerOrder) do
			local p = ns.providers[key]
			if p.Prepare then ns.Try(p.Prepare, p) end
		end
		ns:Fire("REQUEST_SCAN", true)
	elseif cmd == "debug" then
		ns.db.debug = not ns.db.debug
		ns:Print("debug " .. (ns.db.debug and "on" or "off"))
	else
		Usage()
	end
end
