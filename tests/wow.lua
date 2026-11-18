-- Offline WoW API stub. `local W = require("wow")`, then `local GL = W.load()` loads the addon's logic
-- files (every Lua entry in Tabard.toc except Libs\* and UI.lua) into fresh stub state.
local W = {}
W.START = 1794500000

-- Names that exist before any load; everything else in _G is cleared on the next W.load.
local baseline = {}
for k in pairs(_G) do baseline[k] = true end
baseline.W = true

local frames, timers, events

-- The game's string.format stores %d, %i, %c, %o, %u, %x and %X arguments in a 32-bit integer and raises
-- "integer overflow attempting to store N" beyond it; plain Lua 5.1 does not. Copy that here so code that
-- formats large ids (C_Club message positions run to 14 digits) fails offline the way it fails in game.
local plainFormat = string.format
string.format = function(fmt, ...)
    local args, n = { ... }, select("#", ...)
    local i = 0
    for spec in string.gmatch(tostring(fmt), "%%[-+ #0]*%d*%.?%d*(.)") do
        if spec ~= "%" then
            i = i + 1
            local v = args[i]
            if i <= n and string.find("dicouxX", spec, 1, true) and type(v) == "number" and (v > 2147483647 or v < -2147483648) then
                error("integer overflow attempting to store " .. plainFormat("%.0f", v), 2)
            end
        end
    end
    return plainFormat(fmt, ...)
end

-- Frames --------------------------------------------------------------------------------------
local noop = function() end
local frameMethods = {}

local function newFrame(name, parent)
    local f = { _scripts = {}, _hooks = {}, _events = {}, _name = name, _parent = parent, _shown = true, _text = "" }
    setmetatable(f, { __index = function(_, key)
        local m = frameMethods[key]
        if m then return m end
        if type(key) == "string" and key:match("^[A-Z]") then return noop end
        return nil
    end })
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end

function frameMethods.RegisterEvent(f, e) f._events[e] = true end
function frameMethods.RegisterUnitEvent(f, e) f._events[e] = true end
function frameMethods.UnregisterEvent(f, e) f._events[e] = nil end
function frameMethods.UnregisterAllEvents(f) f._events = {} end
function frameMethods.IsEventRegistered(f, e) return f._events[e] == true end
function frameMethods.SetScript(f, hook, fn) f._scripts[hook] = fn end
function frameMethods.GetScript(f, hook) return f._scripts[hook] end
function frameMethods.HookScript(f, hook, fn)
    f._hooks[hook] = f._hooks[hook] or {}
    table.insert(f._hooks[hook], fn)
end
function frameMethods.GetName(f) return f._name end
function frameMethods.GetParent(f) return f._parent end
function frameMethods.Show(f) f._shown = true end
function frameMethods.Hide(f) f._shown = false end
function frameMethods.IsShown(f) return f._shown end
function frameMethods.IsVisible(f) return f._shown end
function frameMethods.SetText(f, t) f._text = t end
function frameMethods.GetText(f) return f._text end
function frameMethods.GetWidth() return 100 end
function frameMethods.GetHeight() return 20 end
function frameMethods.GetStringWidth() return 50 end
function frameMethods.GetNumPoints() return 0 end
function frameMethods.GetFrameLevel() return 1 end
function frameMethods.GetAttribute(f, k) return f._attrs and f._attrs[k] end
function frameMethods.SetAttribute(f, k, v) f._attrs = f._attrs or {}; f._attrs[k] = v end
function frameMethods.CreateTexture(f) return newFrame(nil, f) end
function frameMethods.CreateFontString(f) return newFrame(nil, f) end
function frameMethods.CreateAnimationGroup(f) return newFrame(nil, f) end
function frameMethods.CreateAnimation(f) return newFrame(nil, f) end
function frameMethods.GetFontString(f) return newFrame(nil, f) end
function frameMethods.GetNormalTexture(f) return newFrame(nil, f) end
function frameMethods.GetHighlightTexture(f) return newFrame(nil, f) end
function frameMethods.GetPushedTexture(f) return newFrame(nil, f) end
function frameMethods.GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end

-- C_Club ------------------------------------------------------------------------------------------
-- W.club = { id, streams = { { streamId, name, streamType } }, server = { [streamId] = { message infos, oldest first } },
-- downloaded = { [streamId] = n } }. The client holds the newest n messages of a stream; RequestMoreMessagesBefore
-- grows that by the request size (the test fires CLUB_MESSAGE_HISTORY_RECEIVED itself). W.club survives W.load, so
-- a test can simulate a new session over the same server; installStubs only clears W.clubRequests.
local function clubBefore(a, b)
    return a.epoch < b.epoch or (a.epoch == b.epoch and (a.position or 0) < (b.position or 0))
end

local function clubFirstIndex(streamId)
    local list = W.club.server[streamId] or {}
    local n = (W.club.downloaded or {})[streamId] or 0
    return math.max(#list - n + 1, 1), list
end

function W.makeClubStub()
    local C = {}
    function C.GetGuildClubId() return W.club and W.club.id end
    function C.GetStreams(clubId) return W.club and W.club.streams or {} end
    function C.GetMessageRanges(clubId, streamId)
        local first, list = clubFirstIndex(streamId)
        if #list == 0 or ((W.club.downloaded or {})[streamId] or 0) == 0 then return {} end
        return { { oldestMessageId = list[first].messageId, newestMessageId = list[#list].messageId } }
    end
    function C.GetMessagesInRange(clubId, streamId, oldest, newest)
        local first, list = clubFirstIndex(streamId)
        local out = {}
        for i = first, #list do
            local id = list[i].messageId
            if not clubBefore(id, oldest) and not clubBefore(newest, id) then out[#out + 1] = list[i] end
        end
        return out
    end
    function C.GetMessageInfo(clubId, streamId, messageId)
        for _, info in ipairs(W.club.server[streamId] or {}) do
            if info.messageId.epoch == messageId.epoch and (info.messageId.position or 0) == (messageId.position or 0) then
                return info
            end
        end
    end
    function C.IsBeginningOfStream(clubId, streamId, messageId)
        return ((W.club.downloaded or {})[streamId] or 0) >= #(W.club.server[streamId] or {})
    end
    function C.RequestMoreMessagesBefore(clubId, streamId, messageId, count)
        W.clubRequests[#W.clubRequests + 1] = { clubId = clubId, streamId = streamId, messageId = messageId, count = count }
        local total = #(W.club.server[streamId] or {})
        W.club.downloaded[streamId] = math.min((W.club.downloaded[streamId] or 0) + (count or 0), total)
        return false
    end
    return C
end

-- `count` message infos one second apart from startEpochSeconds, oldest first (position 0).
function W.clubMessages(streamId, count, startEpochSeconds, author)
    local out = {}
    for i = 1, count do
        out[i] = {
            messageId = { epoch = (startEpochSeconds + i - 1) * 1e6, position = 0 },
            author = { name = author or "Ooh Woo" },
            content = "stream " .. streamId .. " message " .. i,
        }
    end
    return out
end

-- A new message arrives on the server and is downloaded at once.
function W.clubPost(streamId, info)
    local list = W.club.server[streamId]
    list[#list + 1] = info
    W.club.downloaded[streamId] = (W.club.downloaded[streamId] or 0) + 1
end

-- Fresh state ----------------------------------------------------------------------------------
local function installStubs()
    for k in pairs(_G) do
        if not baseline[k] then _G[k] = nil end
    end
    frames, timers = {}, {}
    W.chat = {}
    W.rosterRequests = 0
    W.clubRequests = {}
    W.units = { player = { "Zev", "Zev" } }
    W.party = 0
    W.roster, W.gameLog = {}, {}
    W._time = W.START

    function _G.CreateFrame(_, name, parent) return newFrame(name, parent) end
    _G.UIParent = newFrame("UIParent")
    _G.WorldFrame = newFrame("WorldFrame")
    for i = 1, 10 do _G["ChatFrame" .. i .. "EditBox"] = newFrame("ChatFrame" .. i .. "EditBox") end
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) W.chat[#W.chat + 1] = msg end }
    _G.ChatFrame1 = _G.DEFAULT_CHAT_FRAME

    _G.C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
    _G.C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = noop }
    _G.C_AddOns = { GetAddOnMetadata = function(_, field) if field == "Version" then return "1.2.11" end end }
    _G.C_GuildInfo = { GuildRoster = function() W.rosterRequests = W.rosterRequests + 1 end }
    _G.C_Club = W.makeClubStub()
    _G.hooksecurefunc = noop
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = noop
    _G.SlashCmdList = {}
    _G.LibStub = function() return nil end
    _G.strtrim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
    _G.tinsert = table.insert
    _G.tremove = table.remove
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.format = string.format
    _G.strsplit = function(sep, s)
        local out, from = {}, 1
        while true do
            local i = s:find(sep, from, true)
            if not i then out[#out + 1] = s:sub(from) break end
            out[#out + 1] = s:sub(from, i - 1)
            from = i + #sep
        end
        return unpack(out)
    end
    _G.date = os.date
    _G.time = os.time
    _G.RAID_CLASS_COLORS = {}
    _G.LOCALIZED_CLASS_NAMES_MALE = {}
    _G.ERR_GUILD_JOIN_S = "%s has joined the guild."
    _G.ERR_GUILD_LEAVE_S = "%s has left the guild."
    _G.ERR_GUILD_REMOVE_SS = "%s has been kicked out of the guild by %s."
    _G.ERR_GUILD_INVITE_S = "You have invited %s to join your guild."

    _G.GetServerTime = function() return W._time end
    _G.GetTime = function() return W._time - W.START end
    _G.IsInGuild = function() return true end
    _G.GetGuildInfo = function() return "Test Guild" end
    _G.GetRealmName = function() return "Test Realm" end
    _G.UnitName = function(unit)
        local t = W.units[unit]
        if t then return t[1], t[2] end
    end
    _G.GetUnitName = function(unit)
        local t = W.units[unit]
        return t and t.full or nil
    end
    _G.GetNumSubgroupMembers = function() return W.party end
    _G.GetNumGroupMembers = function() return W.party end
    _G.IsInGroup = function() return W.party > 0 end
    _G.IsInRaid = function() return false end

    _G.GetNumGuildMembers = function() return #W.roster end
    _G.GetGuildRosterInfo = function(i)
        local r = W.roster[i]
        if not r then return nil end
        return r.name, r.rank, r.rankIndex, r.level, r.class, r.zone, r.note or "", r.onote or "",
            r.online and true or false, nil, r.class, 0, 0, false, false, 0, r.guid
    end
    _G.GetGuildRosterLastOnline = function(i)
        local r = W.roster[i]
        if not r or r.online then return nil, nil, nil, nil end
        return r.years, r.months, r.days, r.hours
    end
    _G.GetNumGuildEvents = function() return #W.gameLog end
    _G.GetGuildEventInfo = function(i)
        local e = W.gameLog[i]
        if not e then return nil end
        local hours = e.hoursAgo or 0
        return e.kind, e.p1, e.p2, e.rank, 0, 0, math.floor(hours / 24), hours % 24
    end
    _G.QueryGuildEventLog = noop
end

-- Clock and timers -------------------------------------------------------------------------------
function W.now() return W._time end
function W.advance(seconds) W._time = W._time + seconds end

-- Runs every pending C_Timer.After callback, including ones scheduled by those callbacks.
function W.runTimers()
    local guard = 0
    while #timers > 0 do
        local batch = timers
        timers = {}
        for _, fn in ipairs(batch) do fn() end
        guard = guard + 1
        if guard > 1000 then error("timers keep rescheduling") end
    end
end

-- Runs the OnUpdate script of every shown stub frame (the client skips hidden ones) for `seconds` of game time,
-- in `step`-second frames (default 0.25).
function W.tick(seconds, step)
    step = step or 0.25
    for _ = 1, math.ceil(seconds / step) do
        for _, f in ipairs(frames) do
            local fn = f._scripts.OnUpdate
            if fn and f._shown then fn(f, step) end
        end
    end
end

-- Dispatches an event to every stub frame registered for it.
function W.fire(event, ...)
    local list = {}
    for _, f in ipairs(frames) do
        if f._events[event] then list[#list + 1] = f end
    end
    for _, f in ipairs(list) do
        local fn = f._scripts.OnEvent
        if fn then fn(f, event, ...) end
        for _, hook in ipairs(f._hooks.OnEvent or {}) do hook(f, event, ...) end
    end
end

function W.clearChat() W.chat = {} end
function W.setRoster(list) W.roster = list or {} end
function W.setGameLog(list) W.gameLog = list or {} end

function W.scan(GL)
    GL:RequestScan(true)
    W.fire("GUILD_ROSTER_UPDATE")
end

function W.importLog(GL)
    W.fire("GUILD_EVENT_LOG_UPDATE")
end

-- Events in a guild's history matching a kind and a member name (nil = any).
function W.events(guild, kind, who)
    local out = {}
    for _, e in ipairs(guild.events) do
        if (kind == nil or e.k == kind) and (who == nil or e.who == who) then out[#out + 1] = e end
    end
    return out
end

-- Loading ------------------------------------------------------------------------------------------
local function tocFiles()
    local files = {}
    for line in io.lines("Tabard.toc") do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") and line:match("%.lua$")
            and not line:match("^Libs[\\/]") and line ~= "UI.lua" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

-- opts.db is the TabardDB to start from (nil = a first run).
function W.load(opts)
    opts = opts or {}
    installStubs()
    _G.TabardDB = opts.db
    local GL = {}
    for _, path in ipairs(tocFiles()) do
        assert(loadfile(path))("Tabard", GL)
    end
    W.fire("ADDON_LOADED", "Tabard")
    return GL
end

return W
