-- Tabard: guild chat for the Chat tab
-- Shows guild and officer chat as the game holds it this session, for reading it more easily than in the guild
-- window. Nothing is saved: on WoW Forever, C_Club hands addons the text of a message only as a session-local
-- protected code (|Kw3392|k) that the game draws as the words in the session that received it and as "Unknown"
-- after a /reload, so a saved copy is unreadable and words cannot be searched. The client keeps every message it
-- downloaded this session, live ones included, and the Chat tab reads them straight from it. At login each channel
-- is topped up to about the last 250 messages; "Load 100 more" fetches the next 100 older ones, and "Load all
-- history" walks back to the start of the stream.

local ADDON_NAME, GL = ...

local Chat = {}
GL.Chat = Chat

local CHANNELS = { "g", "o" }
local START_DELAY = 5     -- seconds after PLAYER_LOGIN before the first look
local RETRY_EVERY = 10    -- seconds between tries while the club or the roster is not ready
local RETRIES = 6         -- for Start, and for a step that finds nothing downloaded yet
local SETTLE = 2          -- seconds after a history event before the next request
local WATCHDOG = 15       -- seconds without a history event before a request is repeated
local BATCH = 100
local RECENT = 250        -- messages per channel fetched at login
local MORE_REQUESTS = 5   -- per "Load 100 more" press, a safety stop (a press needs one request, a few if the game is slow)
local MAX_REQUESTS = 500  -- per walk, a safety stop (about 50,000 messages)
local STALLS = 3          -- requests in a row that bring nothing older: the start of the stream (see step)
local REQUIRED = { "GetGuildClubId", "GetStreams", "GetMessageRanges", "GetMessagesInRange", "GetMessageInfo",
    "IsBeginningOfStream", "RequestMoreMessagesBefore" }

Chat.disabled = false
Chat.started = false
Chat.tried = false     -- Start has run at least once (PLAYER_LOGIN + 5 s); a roster scan may start it after that
Chat.streams = {}      -- { g = streamId, o = streamId }
Chat.walking = {}      -- channels being fetched: "recent" (the login top-up), "more" (Load 100 more) or "all" (Load all history)
Chat.target = {}       -- the downloaded count a "more" walk stops at, per channel
Chat.pending = {}      -- channels with a request waiting for its history event
Chat.queued = {}       -- channels with a next step already scheduled
Chat.token = {}        -- bumped by every request and every history event; a watchdog only acts if it is unchanged
Chat.requests = {}     -- requests made by the current walk
Chat.waits = {}        -- steps in a row that found nothing downloaded
Chat.atStart = {}      -- channels whose whole history is downloaded (or that stayed empty) this session
Chat.lastAsked = {}    -- the oldest message id the last request asked before
Chat.stalls = {}       -- steps in a row whose downloaded range came back no older than that request asked

local function before(e1, p1, e2, p2)
    return e1 < e2 or (e1 == e2 and p1 < p2)
end

local function validId(id)
    return type(id) == "table" and type(id.epoch) == "number"
end

local function idBefore(a, b)
    return before(a.epoch, a.position or 0, b.epoch, b.position or 0)
end

local function capable()
    if type(C_Club) ~= "table" then return false end
    for _, name in ipairs(REQUIRED) do
        if type(C_Club[name]) ~= "function" then return false end
    end
    return true
end

-- Officers and up (the rank whose shared data Sync trusts), unless switched off in Settings.
function Chat:Eligible()
    if GL.settings and GL.settings.chatArchive == false then return false end
    local guild = GL:Guild()
    if not guild then return false end
    local member = GL:Member(guild, GL:PlayerName())
    if not (member and type(member.rankIndex) == "number") then return false end
    return member.rankIndex <= ((GL.settings and GL.settings.syncMinRank) or 1)
end

-- A C_Club call that raises turns the Chat tab's fetching off for the session, with one line to say why.
function Chat:Fail(err)
    if self.disabled then return end
    self.disabled = true
    GL:Print("guild chat is off for this session: " .. tostring(err))
end

-- Returns ok, result. A missing C_Club (or a missing function) turns it off without a word.
function Chat:Call(name, ...)
    if self.disabled then return false end
    if not capable() then
        self.disabled = true
        return false
    end
    local ok, result = pcall(C_Club[name], ...)
    if not ok then
        self:Fail(result)
        return false
    end
    return true, result
end

-- At most one GL:OnChatChanged per second, however many messages or walk changes came in.
function Chat:Changed()
    if self.changeQueued then return end
    self.changeQueued = true
    C_Timer.After(1, function()
        self.changeQueued = false
        if GL.OnChatChanged then GL:OnChatChanged() end
    end)
end

-- The stream ids of guild and officer chat, and the club id. Matched by stream type, then by name.
function Chat:Streams()
    local out = {}
    local ok, club = self:Call("GetGuildClubId")
    if not ok or not club then return out, nil end
    local ok2, list = self:Call("GetStreams", club)
    if not ok2 or type(list) ~= "table" then return out, club end
    local types = Enum and Enum.ClubStreamType
    local guildType = types and types.Guild or 1
    local officerType = types and (types.Officer or types.Officers) or 2
    for _, stream in ipairs(list) do
        if type(stream) == "table" and stream.streamId ~= nil then
            if stream.streamType == guildType then out.g = out.g or stream.streamId
            elseif stream.streamType == officerType then out.o = out.o or stream.streamId end
        end
    end
    for _, stream in ipairs(list) do
        if type(stream) == "table" and stream.streamId ~= nil then
            if not out.g and stream.name == "Guild" then out.g = stream.streamId
            elseif not out.o and (stream.name == "Officer" or stream.name == "Officers") then out.o = stream.streamId end
        end
    end
    return out, club
end

-- A channel's downloaded ranges, and the one holding the newest message (live messages extend it, and the
-- client fetches older history onto it).
function Chat:Ranges(ch)
    local ok, ranges = self:Call("GetMessageRanges", self.clubId, self.streams[ch])
    if not ok or type(ranges) ~= "table" then return nil, nil end
    local main
    for _, range in ipairs(ranges) do
        if type(range) == "table" and validId(range.oldestMessageId) and validId(range.newestMessageId)
            and (not main or idBefore(main.newestMessageId, range.newestMessageId)) then
            main = range
        end
    end
    return ranges, main
end

local function infosIn(self, ch, range)
    local ok, infos = self:Call("GetMessagesInRange", self.clubId, self.streams[ch], range.oldestMessageId, range.newestMessageId)
    return ok and type(infos) == "table" and infos or {}
end

-- One message info as a record, or nil for a destroyed or malformed one. The text stays as the game gave it (a
-- protected code the game draws as the words).
local function toRecord(ch, info)
    if type(info) ~= "table" or info.destroyed or not validId(info.messageId) then return nil end
    local author = info.author and GL:ShortName(info.author.name)
    return { epoch = info.messageId.epoch, pos = info.messageId.position or 0, ch = ch,
        author = (author and author ~= "") and author or "?", text = type(info.content) == "string" and info.content or "" }
end

-- Every downloaded message, oldest first, as { epoch (microseconds), pos, ch, author, text }. filter fields are
-- optional: channels (set of "g"/"o"; nil = both), authors (set of names), since (Unix seconds).
function Chat:Messages(filter)
    filter = filter or {}
    local out = {}
    if self.disabled or not self.started then return out end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and (not filter.channels or filter.channels[ch]) then
            local ranges = self:Ranges(ch)
            for _, range in ipairs(ranges or {}) do
                if type(range) == "table" and validId(range.oldestMessageId) and validId(range.newestMessageId) then
                    for _, info in ipairs(infosIn(self, ch, range)) do
                        local ok, rec = pcall(toRecord, ch, info)
                        if ok and rec and (not filter.since or rec.epoch / 1e6 >= filter.since)
                            and (not filter.authors or filter.authors[rec.author]) then
                            out[#out + 1] = rec
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return before(a.epoch, a.pos, b.epoch, b.pos) end)
    return out
end

-- Fetching ----------------------------------------------------------------------------------------------------
-- Asks for 100 messages older than `oldest`. The reply arrives as CLUB_MESSAGE_HISTORY_RECEIVED; if it never does,
-- the watchdog clears the wait and tries the step again.
function Chat:Request(ch, oldest)
    local ok = self:Call("RequestMoreMessagesBefore", self.clubId, self.streams[ch], oldest, BATCH)
    if not ok then return end
    self.lastAsked[ch] = { oldest.epoch, oldest.position or 0 }
    self.pending[ch] = true
    self.token[ch] = (self.token[ch] or 0) + 1
    local token = self.token[ch]
    C_Timer.After(WATCHDOG, function()
        if self.disabled or self.token[ch] ~= token then return end
        self.pending[ch] = nil
        if self.walking[ch] then self:Step(ch) end
    end)
end

-- One step of a channel's walk: stop at the start of the stream (or, for the login top-up, once 250 messages are
-- downloaded; for Load 100 more, once 100 more are), otherwise ask for 100 more.
local function step(self, ch)
    self.queued[ch] = nil
    local mode = self.walking[ch]
    if self.disabled or not mode then return end
    if not self:Eligible() then
        self.walking[ch] = nil
        return
    end
    local _, main = self:Ranges(ch)
    if self.disabled then return end
    local oldest = main and main.oldestMessageId
    if not oldest then
        -- Nothing downloaded: right after login the client may still be fetching. Look again a few times; a stream
        -- still empty after that has nothing to show.
        self.waits[ch] = (self.waits[ch] or 0) + 1
        if self.waits[ch] > RETRIES then
            self.walking[ch], self.atStart[ch] = nil, true
        else
            C_Timer.After(WATCHDOG, function()
                if self.walking[ch] and not self.pending[ch] and not self.queued[ch] then self:Step(ch) end
            end)
        end
        return
    end
    self.waits[ch] = 0
    if mode == "recent" and #infosIn(self, ch, main) >= RECENT then
        self.walking[ch] = nil
        return
    end
    if mode == "more" and #infosIn(self, ch, main) >= (self.target[ch] or 0) then
        self.walking[ch] = nil
        return
    end
    local ok, begin = self:Call("IsBeginningOfStream", self.clubId, self.streams[ch], oldest)
    if self.disabled then return end
    -- WoW Forever answers false even at the guild's first message, so a request that brings nothing older, a few
    -- times running, also means the start.
    local asked = self.lastAsked[ch]
    if asked and asked[1] == oldest.epoch and asked[2] == (oldest.position or 0) then
        self.stalls[ch] = (self.stalls[ch] or 0) + 1
    else
        self.stalls[ch] = 0
    end
    if (ok and begin) or self.stalls[ch] >= STALLS then
        self.walking[ch], self.atStart[ch] = nil, true
        return
    end
    if self.requests[ch] >= (mode == "more" and MORE_REQUESTS or MAX_REQUESTS) then
        self.walking[ch] = nil
        return
    end
    self.requests[ch] = self.requests[ch] + 1
    self:Request(ch, oldest)
end

-- A walk that ends tells the Chat page (its button and status line follow the walks).
function Chat:Step(ch)
    local running = self.walking[ch]
    step(self, ch)
    if running and not self.walking[ch] then self:Changed() end
end

function Chat:Walk(ch, mode)
    self.walking[ch], self.requests[ch] = mode, 0
    self.lastAsked[ch], self.stalls[ch] = nil, 0   -- stalls are counted within one walk
    if not self.pending[ch] and not self.queued[ch] then self:Step(ch) end
end

-- Called PLAYER_LOGIN + 5 s, and again from the Settings checkbox or a roster scan. Retries while the club, the
-- streams or the roster are not ready. Once started, a further call does nothing.
function Chat:Start(retries)
    retries = retries or 0
    self.tried = true
    if self.disabled or self.started then return end
    if not capable() then
        self.disabled = true
        return
    end
    if self:Eligible() then
        local streams, club = self:Streams()
        if self.disabled then return end
        if club and (streams.g or streams.o) then
            self.started, self.clubId, self.streams = true, club, streams
            for _, ch in ipairs(CHANNELS) do
                if streams[ch] then self:Walk(ch, "recent") end
            end
            self:Changed()
            return
        end
    end
    -- One retry chain at a time, however many callers.
    if retries < RETRIES and not self.retryQueued then
        self.retryQueued = true
        C_Timer.After(RETRY_EVERY, function()
            self.retryQueued = nil
            self:Start(retries + 1)
        end)
    end
end

-- The "Load all history" button: walk every channel back to the start of its stream.
function Chat:LoadAll()
    if self.disabled or not self.started or not self:Eligible() or self:Loading() then return end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and not self.atStart[ch] and self.walking[ch] ~= "all" then self:Walk(ch, "all") end
    end
    self:Changed()
end

-- The "Load 100 more" button: fetch the next 100 older messages of each given channel (a set like { g = true };
-- nil means both). Ignored while anything is loading.
function Chat:LoadMore(channels)
    if self.disabled or not self.started or not self:Eligible() or self:Loading() then return end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and (not channels or channels[ch]) and not self.atStart[ch] then
            local _, main = self:Ranges(ch)
            if self.disabled then return end
            local have = main and #infosIn(self, ch, main) or 0
            self.target[ch] = have + BATCH
            self:Walk(ch, "more")
        end
    end
    self:Changed()
end

-- Any channel being fetched (the login top-up, Load 100 more or Load all history).
function Chat:Loading()
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and self.walking[ch] then return true end
    end
    return false
end

-- Every channel's (in the given set, nil meaning both) whole history is downloaded this session.
function Chat:AllLoaded(channels)
    if not self.started then return false end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and (not channels or channels[ch]) and not self.atStart[ch] then return false end
    end
    return true
end

-- Where the "unread" line goes in a list of messages (oldest first, epoch in microseconds): the index of the first
-- message newer than `since` (Unix seconds), or nil when there is no marker, nothing is newer, that message is the
-- first one shown (a line above everything would say nothing), or it may not be loaded: every channel in `channels`
-- (a set, nil meaning both) that has a stream must either be downloaded to its start or reach back to `since`,
-- otherwise older unread messages of that channel are missing and the line would sit in the wrong place. A channel
-- with nothing downloaded yet (right after a fresh login the game may not have fetched it) has no loaded messages
-- the line could be wrong about, so it does not hold the line back; once its messages arrive it counts like the rest.
function Chat:FirstUnread(messages, since, channels)
    if type(since) ~= "number" then return nil end
    if self.started then
        for _, ch in ipairs(CHANNELS) do
            if self.streams[ch] and (not channels or channels[ch]) and not self.atStart[ch] then
                local _, main = self:Ranges(ch)
                if self.disabled then return nil end
                if main and not (main.oldestMessageId.epoch / 1e6 <= since) then return nil end
            end
        end
    end
    for i, m in ipairs(messages) do
        if m.epoch / 1e6 > since then return i > 1 and i or nil end
    end
    return nil
end

-- The Chat page's status line: says something only while older messages are being fetched (or it is off).
function Chat:Status()
    if self.disabled or not self:Eligible() then return "Guild chat is off" end
    return self:Loading() and "Loading older messages\226\128\166" or ""
end

-- CLUB_MESSAGE_ADDED(clubId, streamId, messageId): a new message the client already holds.
function Chat:OnMessageAdded(clubId, streamId)
    if self.disabled or not self.started or clubId ~= self.clubId then return end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] ~= nil and self.streams[ch] == streamId then self:Changed() return end
    end
end

-- CLUB_MESSAGE_HISTORY_RECEIVED(clubId, streamId, ...): older messages arrived. The payload on WoW Forever is not
-- known beyond the first two arguments, so an unknown stream id means "every channel".
function Chat:OnHistory(clubId, streamId)
    if self.disabled or not self.started then return end
    if clubId ~= nil and clubId ~= self.clubId then return end
    for _, ch in ipairs(CHANNELS) do
        local stream = self.streams[ch]
        if stream ~= nil and (streamId == nil or streamId == stream) then
            self.token[ch] = (self.token[ch] or 0) + 1
            self.pending[ch] = nil
            self:Changed()
            if self.walking[ch] and not self.queued[ch] then
                self.queued[ch] = true
                C_Timer.After(SETTLE, function() self:Step(ch) end)
            end
        end
    end
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "CLUB_MESSAGE_ADDED", "CLUB_MESSAGE_HISTORY_RECEIVED", "GUILD_ROSTER_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        -- 1.4.0 saved chat to disk; on Forever that copy is protected codes that read "Unknown", so it goes.
        if GL.db then GL.db.chat = nil end
        C_Timer.After(START_DELAY, function() Chat:Start() end)
    elseif event == "GUILD_ROSTER_UPDATE" then
        -- Scan.lua (loaded first) has read the roster by now: a promotion or a late roster after the login tries
        -- gave up can start it without a /reload.
        if Chat.tried and not Chat.started and not Chat.disabled and Chat:Eligible() then Chat:Start() end
    elseif event == "CLUB_MESSAGE_ADDED" then
        Chat:OnMessageAdded(...)
    elseif event == "CLUB_MESSAGE_HISTORY_RECEIVED" then
        Chat:OnHistory(...)
    end
end)
