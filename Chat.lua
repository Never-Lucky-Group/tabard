-- Tabard: the guild chat archive
-- A permanent, searchable copy of guild and officer chat, kept per guild in TabardDB.chat and never sent to
-- anyone: it stays on this machine. Each local day is one string of records, not a table per message. A saved
-- file with more than about 262,000 string constants fails to load in Lua 5.1 ("constant table overflow"), and
-- a year of chat is around 100,000 messages; one string per day also costs about 40% less memory. The archive
-- lives beside the guild records (GL.db.chat), not inside them, so GL:Backup never copies it.

local ADDON_NAME, GL = ...

local Chat = {}
GL.Chat = Chat

local FIELD = "\031"   -- between the fields of one record
local RECORD = "\030"  -- between the records of one day

-- Dedupe sets, one per store and day, built the first time a day is written to. Weak on the store so a
-- dropped database does not stay alive here.
local seenKeys = setmetatable({}, { __mode = "k" })

-- Encoding ----------------------------------------------------------------------------------------------------
local function clean(s)
    return (string.gsub(tostring(s or ""), "[\030\031]", ""))
end

-- The game's stand-in for message text it does not hold. One capture on Forever saved "Unknown" as the text of
-- thousands of messages (a clean capture did not repeat it), so a stand-in is never archived, and a saved one
-- gives way to the real text when that comes along. The cost: a message that is only the word "Unknown" is lost.
local STAND_IN = "stand-in"
local function standIn(text)
    return text == "Unknown" or (type(UNKNOWNOBJECT) == "string" and text == UNKNOWNOBJECT)
        or (type(UNKNOWN) == "string" and text == UNKNOWN)
end

-- %.0f keeps all sixteen digits of a microsecond epoch (tostring would turn it into 1.763e+15), and the 14-digit
-- C_Club positions Forever sends: the game's %d only takes 32-bit integers and raises "integer overflow" past them.
function Chat.Encode(rec)
    return string.format("%.0f", rec.epoch) .. FIELD .. string.format("%.0f", rec.pos or 0) .. FIELD .. rec.ch
        .. FIELD .. rec.author .. FIELD .. rec.text
end

function Chat.Decode(line)
    local epoch, pos, ch, author, text = string.match(line, "^(%d+)\031(%d+)\031(.)\031([^\031]*)\031(.*)$")
    if not epoch then return nil end
    return { epoch = tonumber(epoch), pos = tonumber(pos), ch = ch, author = author, text = text }
end

-- The epoch and pos of an encoded record without decoding the rest of it.
local function rawId(line)
    local epoch, pos = string.match(line, "^(%d+)\031(%d+)\031")
    return tonumber(epoch), tonumber(pos)
end

local function split(day)
    local out, from = {}, 1
    while true do
        local i = string.find(day, RECORD, from, true)
        if not i then out[#out + 1] = string.sub(day, from) break end
        out[#out + 1] = string.sub(day, from, i - 1)
        from = i + 1
    end
    return out
end

local function dayKeyOf(epoch)
    return date("%Y%m%d", math.floor(epoch / 1e6))
end

local function sortedDays(store)
    local keys = {}
    for key in pairs(store.days) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function before(e1, p1, e2, p2)
    return e1 < e2 or (e1 == e2 and p1 < p2)
end

local function idKey(epoch, pos)
    return string.format("%.0f", epoch) .. ":" .. string.format("%.0f", pos)
end

-- Storage ---------------------------------------------------------------------------------------------------
function Chat:Store(guildKey)
    if not (GL.db and guildKey) then return nil end
    GL.db.chat = GL.db.chat or {}
    local store = GL.db.chat[guildKey]
    if not store then
        store = { days = {}, newest = {}, caughtUp = {}, begin = {}, v = 2 }
        GL.db.chat[guildKey] = store
    end
    -- 1.4.0 could not archive Forever's 14-digit message positions yet still marked how far back the archive was
    -- complete; drop those marks once so the next backfill walks the server's history again (duplicates are skipped).
    if store.v ~= 2 then store.caughtUp, store.begin, store.v = {}, {}, 2 end
    store.days = store.days or {}
    store.newest = store.newest or {}
    store.caughtUp = store.caughtUp or {}
    store.begin = store.begin or {}
    return store
end

local function daySet(store, key)
    local sets = seenKeys[store]
    if not sets then
        sets = {}
        seenKeys[store] = sets
    end
    local set = sets[key]
    if not set then
        set = {}
        local day = store.days[key]
        if day then
            for _, line in ipairs(split(day)) do
                local epoch, pos = rawId(line)
                if epoch then set[idKey(epoch, pos)] = standIn(string.match(line, "\031([^\031]*)$")) and STAND_IN or true end
            end
        end
        sets[key] = set
    end
    return set
end

function Chat:Add(store, rec)
    if not (store and rec and type(rec.epoch) == "number" and (rec.ch == "g" or rec.ch == "o")) then return false end
    local pos = rec.pos or 0
    local key = dayKeyOf(rec.epoch)
    local set = daySet(store, key)
    local id = idKey(rec.epoch, pos)
    local text = clean(rec.text)
    if set[id] then
        if set[id] ~= STAND_IN or standIn(text) then return false end
        -- A saved stand-in and now the real text: put the text into the saved record.
        local lines = split(store.days[key])
        for i, existing in ipairs(lines) do
            local e, p = rawId(existing)
            if e == rec.epoch and p == pos then
                local old = Chat.Decode(existing)
                if old then lines[i] = Chat.Encode({ epoch = old.epoch, pos = old.pos, ch = old.ch, author = old.author, text = text }) end
                break
            end
        end
        store.days[key] = table.concat(lines, RECORD)
        set[id] = true
        return true
    end
    local line = Chat.Encode({
        epoch = rec.epoch, pos = pos, ch = rec.ch,
        author = (rec.author and rec.author ~= "") and clean(rec.author) or "?",
        text = text,
    })
    local day = store.days[key]
    if not day then
        store.days[key] = line
    else
        -- Chat arrives in time order, so the new record almost always belongs at the end of its day.
        local lastStart = string.match(day, "^.*()" .. RECORD)
        local lastEpoch, lastPos = rawId(lastStart and string.sub(day, lastStart + 1) or day)
        if not lastEpoch or before(lastEpoch, lastPos, rec.epoch, pos) then
            store.days[key] = day .. RECORD .. line
        else
            local lines = split(day)
            local at = #lines + 1
            for i, existing in ipairs(lines) do
                local e, p = rawId(existing)
                if e and before(rec.epoch, pos, e, p) then at = i break end
            end
            table.insert(lines, at, line)
            store.days[key] = table.concat(lines, RECORD)
        end
    end
    set[id] = standIn(text) and STAND_IN or true
    local newest = store.newest[rec.ch]
    if not newest or before(newest[1], newest[2], rec.epoch, pos) then
        store.newest[rec.ch] = { rec.epoch, pos }
    end
    return true
end

-- Records in time order. Raw checks (channel, a text prefilter, the time) run on the encoded record, and
-- only the survivors are decoded and checked exactly.
function Chat:Query(store, filter)
    local out = {}
    if not store then return out end
    filter = filter or {}
    local needle = filter.text and filter.text ~= "" and string.lower(filter.text) or nil
    local sinceEpoch = filter.since and filter.since * 1e6 or nil
    local sinceKey = filter.since and date("%Y%m%d", filter.since) or nil
    for _, key in ipairs(sortedDays(store)) do
        if not sinceKey or key >= sinceKey then
            for _, line in ipairs(split(store.days[key])) do
                local pass = true
                if needle and not string.find(string.lower(line), needle, 1, true) then pass = false end
                if pass and filter.channels then
                    local ch = string.match(line, "^%d+\031%d+\031(.)\031")
                    if not (ch and filter.channels[ch]) then pass = false end
                end
                if pass then
                    local rec = Chat.Decode(line)
                    if rec
                        and (not sinceEpoch or rec.epoch >= sinceEpoch)
                        and (not filter.authors or filter.authors[rec.author])
                        and (not needle or string.find(string.lower(rec.text), needle, 1, true)) then
                        out[#out + 1] = rec
                    end
                end
            end
        end
    end
    return out
end

local function countIn(day)
    local n = 1
    for _ in string.gmatch(day, RECORD) do n = n + 1 end
    return n
end

function Chat:Count(store)
    local n = 0
    if not store then return n end
    for _, day in pairs(store.days) do n = n + countIn(day) end
    return n
end

function Chat:Bytes(store)
    local n = 0
    if not store then return n end
    for _, day in pairs(store.days) do n = n + #day end
    return n
end

function Chat:NewestId(store, ch)
    local newest = store and store.newest and store.newest[ch]
    if newest then return newest[1], newest[2] end
    return nil
end

-- The epoch and pos of a channel's oldest archived record, or nil. Reads from the oldest day up, so it is cheap for
-- guild chat (found on the first day) and costs a scan only for a channel with few records.
function Chat:OldestId(store, ch)
    if not store then return nil end
    for _, key in ipairs(sortedDays(store)) do
        for _, line in ipairs(split(store.days[key])) do
            if string.match(line, "^%d+\031%d+\031(.)\031") == ch then return rawId(line) end
        end
    end
    return nil
end

-- Housekeeping ----------------------------------------------------------------------------------------------
-- Drops whole days older than keepDays. 0 or nil keeps everything.
function Chat:Trim(store, keepDays, now)
    if not store or not keepDays or keepDays <= 0 then return 0 end
    local cutoff = date("%Y%m%d", (now or GL:Now()) - keepDays * 86400)
    local removed = 0
    for key, day in pairs(store.days) do
        if key < cutoff then
            removed = removed + countIn(day)
            store.days[key] = nil
            if seenKeys[store] then seenKeys[store][key] = nil end
        end
    end
    if removed > 0 then
        -- The archive no longer reaches the server's beginning (store.begin), so "load older" may fetch again.
        store.begin = {}
        -- The newest records could only have gone if every day did; rebuild from what is left.
        store.newest = {}
        for _, key in ipairs(sortedDays(store)) do
            for _, line in ipairs(split(store.days[key])) do
                local rec = Chat.Decode(line)
                if rec then
                    local cur = store.newest[rec.ch]
                    if not cur or before(cur[1], cur[2], rec.epoch, rec.pos) then store.newest[rec.ch] = { rec.epoch, rec.pos } end
                end
            end
        end
    end
    return removed
end

-- The archive is for the people who can see officer chat: ranks up to syncMinRank (the same bar sharing uses),
-- so a member who cannot read it live cannot read it later either.
function Chat:Eligible()
    if GL.settings and GL.settings.chatArchive == false then return false end
    local guild = GL:Guild()
    if not guild then return false end
    local member = GL:Member(guild, GL:PlayerName())
    if not (member and type(member.rankIndex) == "number") then return false end
    return member.rankIndex <= ((GL.settings and GL.settings.syncMinRank) or 1)
end

-- Capture ---------------------------------------------------------------------------------------------------
-- The client downloads guild and officer chat on its own (C_Club): the newest 100 messages are there right after
-- login, and RequestMoreMessagesBefore pulls older ones. Tabard copies what is downloaded, copies new messages as
-- they arrive, and backfills the stretch between the last archived message and the oldest downloaded one so the
-- archive has no holes. store.caughtUp[ch] marks how far the archive is known to be complete and moves only when
-- a backfill finishes (or stops at the request cap), so an interrupted backfill is picked up again, up to the same
-- target, by the next session. store.begin[ch] is set once the archive holds the first message the server has, so
-- "load older" knows there is nothing left to fetch.
-- (store.newest is only the newest archived message; Chat:Add advances it for every message, live ones included.)
local CHANNELS = { "g", "o" }
local START_DELAY = 5     -- seconds after PLAYER_LOGIN before the first look
local RETRY_EVERY = 10    -- seconds between tries while the club or the roster is not ready
local RETRIES = 6         -- for Start, and for a step that finds nothing downloaded yet
local SETTLE = 2          -- seconds after a history event before the next request
local WATCHDOG = 15       -- seconds without a history event before a request is repeated
local MAX_REQUESTS = 200  -- per channel and session for the backfill, and per "load older" walk
local BATCH = 100
local STALLS = 3          -- requests in a row that bring nothing older: the start of the stream (see step)
local REQUIRED = { "GetGuildClubId", "GetStreams", "GetMessageRanges", "GetMessagesInRange", "GetMessageInfo",
    "IsBeginningOfStream", "RequestMoreMessagesBefore" }

Chat.disabled = false
Chat.started = false
Chat.tried = false     -- Start has run at least once (PLAYER_LOGIN + 5 s); a roster scan may start capture after that
Chat.loginMark = nil   -- the newest archived epoch (microseconds) when this session began; nil for an empty archive
Chat.streams = {}      -- { g = streamId, o = streamId }
Chat.baseline = {}     -- store.caughtUp[ch] as it was at Start: how far back the backfill must reach
Chat.active = {}       -- channels with a walk running: "backfill", or "older" for a "load older" walk
Chat.pending = {}      -- channels with a request waiting for its history event
Chat.atStart = {}      -- channels whose stream stayed empty this session (nothing to load, but nothing saved either)
Chat.queued = {}       -- channels with a next step already scheduled
Chat.token = {}        -- bumped by every request and every history event; a watchdog only acts if it is unchanged
Chat.requestCount = {}
Chat.waits = {}        -- steps in a row that found nothing downloaded
Chat.readFrom = {}     -- the oldest and newest message ids already read from the client, per channel: a step reads
Chat.readTo = {}       -- only what the downloaded range gained beyond them
Chat.goal = {}         -- for a "load older" walk: the archive's oldest record when it began, or false for none
Chat.beyond = {}       -- for a "load older" walk: the batch past the archive's oldest has been asked for
Chat.olderCount = {}   -- requests made by the current "load older" walk
Chat.lastAsked = {}    -- the oldest message id the last request asked before, per channel (kept for the session)
Chat.stalls = {}       -- steps in a row whose downloaded range came back no older than that request asked
Chat.changedFrom = nil -- the oldest epoch archived since the last GL:OnChatChanged
Chat.messageErrors = 0

local function capable()
    if type(C_Club) ~= "table" then return false end
    for _, name in ipairs(REQUIRED) do
        if type(C_Club[name]) ~= "function" then return false end
    end
    return true
end

local function validId(id)
    return type(id) == "table" and type(id.epoch) == "number"
end

local function idBefore(a, b)
    return before(a.epoch, a.position or 0, b.epoch, b.position or 0)
end

-- A C_Club call that raises turns capture off for the session, with one line to say why.
function Chat:Fail(err)
    if self.disabled then return end
    self.disabled = true
    GL:Print("guild chat archive is off for this session: " .. tostring(err))
end

-- Returns ok, result. A missing C_Club (or a missing function) turns capture off without a word.
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

-- At most one GL:OnChatChanged per second, however many messages came in. It is passed the oldest epoch archived
-- since the previous call, so the Chat page can tell new messages at the end from older ones filled in.
function Chat:Changed()
    if self.changeQueued then return end
    self.changeQueued = true
    C_Timer.After(1, function()
        self.changeQueued = false
        local from = self.changedFrom
        self.changedFrom = nil
        if GL.OnChatChanged then GL:OnChatChanged(from) end
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

-- One message info as an archive record, or nil for a destroyed message. Raises on a malformed one.
local function toRecord(ch, info)
    if info.destroyed then return nil end
    local id = info.messageId
    if type(id.epoch) ~= "number" then error("message has no epoch") end
    if standIn(info.content) then error("the game had not loaded its text yet") end
    return {
        epoch = id.epoch, pos = id.position or 0, ch = ch,
        author = GL:ShortName(info.author and info.author.name) or "?",
        text = info.content,
    }
end

-- An error on one message skips that message; the first one is mentioned, the rest are only counted.
function Chat:Archive(ch, info)
    local ok, result = pcall(function()
        local rec = toRecord(ch, info)
        if rec and Chat:Add(self.store, rec) then
            if not self.changedFrom or rec.epoch < self.changedFrom then self.changedFrom = rec.epoch end
            return true
        end
        return false
    end)
    if not ok then
        self.messageErrors = self.messageErrors + 1
        if self.messageErrors == 1 then GL:Print("guild chat archive skipped a message it could not read: " .. tostring(result)) end
        return false
    end
    return result
end

-- The downloaded ranges of a channel, and the one holding the newest message: the range live messages extend and a
-- backfill walks back from. An older range apart from it (a gap the client has not filled) is not walked from, so a
-- backfill cannot finish over unread messages in the gap.
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

-- Archives what the client has downloaded for a channel. The first read (or `full`) takes every range; after that,
-- while the newest range still holds everything read before, only what it gained at either end is read, so each
-- step of a long backfill costs one batch, not the whole downloaded history. Returns how many messages were new.
function Chat:ReadDownloaded(ch, full)
    local stream = self.streams[ch]
    if self.disabled or not (self.store and stream) then return 0 end
    local ranges, main = self:Ranges(ch)
    if not ranges then return 0 end
    local added = 0
    local function read(oldest, newest)
        local ok, infos = self:Call("GetMessagesInRange", self.clubId, stream, oldest, newest)
        if not ok then return false end
        if type(infos) == "table" then
            for _, info in ipairs(infos) do
                if type(info) == "table" and self:Archive(ch, info) then added = added + 1 end
            end
        end
        return true
    end
    local from, to = self.readFrom[ch], self.readTo[ch]
    local oldest, newest = main and main.oldestMessageId, main and main.newestMessageId
    if not full and main and from and to and not idBefore(from, oldest) and not idBefore(newest, to) then
        if idBefore(oldest, from) and not read(oldest, from) then return added end
        if idBefore(to, newest) and not read(to, newest) then return added end
    else
        for _, range in ipairs(ranges) do
            if type(range) == "table" and not read(range.oldestMessageId, range.newestMessageId) then return added end
        end
    end
    self.readFrom[ch], self.readTo[ch] = oldest, newest
    if added > 0 then self:Changed() end
    return added
end

-- The oldest downloaded message id of a channel's newest range (the id table itself, to hand back to C_Club), or nil.
function Chat:Oldest(ch)
    local _, main = self:Ranges(ch)
    return main and main.oldestMessageId
end

-- Asks for 100 messages older than `oldest`. The reply arrives as CLUB_MESSAGE_HISTORY_RECEIVED; if it never does,
-- the watchdog clears the wait and, for a running walk, tries the step again.
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
        if self.active[ch] then self:Step(ch) end
    end)
end

-- Ends a channel's walk; a backfill also records that the archive is complete up to its newest message.
function Chat:Finish(ch)
    local mode = self.active[ch]
    self.active[ch], self.pending[ch] = nil, nil
    if mode == "backfill" then
        local epoch, pos = Chat:NewestId(self.store, ch)
        -- A message skipped this session is a hole the mark would hide for good; leave it for a later session.
        if epoch and self.messageErrors == 0 then self.store.caughtUp[ch] = { epoch, pos } end
    end
end

-- One step of a channel's walk. A backfill is done when the downloaded range reaches what was archived before (or
-- the beginning of the stream); a "load older" walk asks back until the downloaded range reaches the archive's
-- oldest record, then for one batch past it. Otherwise ask for 100 more.
local function step(self, ch)
    self.queued[ch] = nil
    local mode = self.active[ch]
    if self.disabled or not mode then return end
    if not self:Eligible() then
        self.active[ch] = nil
        return
    end
    -- Archive what the client holds before judging the range: a history event may have been missed or never sent,
    -- and completing over unread messages would leave a hole.
    self:ReadDownloaded(ch)
    if self.disabled then return end
    local oldest = self:Oldest(ch)
    if self.disabled then return end
    if not oldest then
        -- Nothing downloaded: right after login the client may still be fetching, so this is not the start of the
        -- stream. Look again a few times; a stream still empty after that is taken as empty for this session only.
        if mode == "older" then self.active[ch] = nil return end
        self.waits[ch] = (self.waits[ch] or 0) + 1
        if self.waits[ch] > RETRIES then
            self.active[ch], self.atStart[ch] = nil, true
        else
            C_Timer.After(WATCHDOG, function()
                if self.active[ch] and not self.pending[ch] and not self.queued[ch] then self:Step(ch) end
            end)
        end
        return
    end
    self.waits[ch] = 0
    if mode == "backfill" then
        local target = self.baseline[ch]
        if target and not before(target[1], target[2], oldest.epoch, oldest.position or 0) then
            self:Finish(ch)
            return
        end
    end
    local ok, begin = self:Call("IsBeginningOfStream", self.clubId, self.streams[ch], oldest)
    if self.disabled then return end
    -- WoW Forever answers false even at the guild's first message, so a request that brings nothing older, a few
    -- times running, also means the start. Kept across walks: "load older" after a finished backfill counts on.
    local asked = self.lastAsked[ch]
    if asked and asked[1] == oldest.epoch and asked[2] == (oldest.position or 0) then
        self.stalls[ch] = (self.stalls[ch] or 0) + 1
    else
        self.stalls[ch] = 0
    end
    if (ok and begin) or self.stalls[ch] >= STALLS then
        if self.messageErrors == 0 then self.store.begin[ch] = true end
        self:Finish(ch)
        return
    end
    if mode == "older" then
        if self.beyond[ch] or self.olderCount[ch] >= MAX_REQUESTS then
            self.active[ch] = nil
            return
        end
        if self.goal[ch] == nil then
            local epoch, pos = Chat:OldestId(self.store, ch)
            self.goal[ch] = epoch and { epoch, pos } or false
        end
        local goal = self.goal[ch]
        if not (goal and before(goal[1], goal[2], oldest.epoch, oldest.position or 0)) then self.beyond[ch] = true end
        self.olderCount[ch] = self.olderCount[ch] + 1
        self:Request(ch, oldest)
        return
    end
    if self.requestCount[ch] >= MAX_REQUESTS then
        -- Recorded as caught up all the same, or every later login would repeat the same walk; what lies further
        -- back can still be fetched with "load older".
        self:Finish(ch)
        GL:Print(string.format("guild chat archive: stopped catching up after %d requests; %s chat from before %s may be missing.",
            MAX_REQUESTS, ch == "o" and "officer" or "guild", date("%d %b %Y", math.floor(oldest.epoch / 1e6))))
        return
    end
    self.requestCount[ch] = self.requestCount[ch] + 1
    self:Request(ch, oldest)
end

-- A walk that ends tells the Chat page its status line may have changed (nothing to re-read in the archive).
function Chat:Step(ch)
    local running = self.active[ch]
    step(self, ch)
    if running and not self.active[ch] and GL.OnChatStatus then GL:OnChatStatus() end
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
        local key = GL:GuildKey()
        local store = key and club and (streams.g or streams.o) and self:Store(key)
        if store then
            self.started, self.clubId, self.streams, self.store = true, club, streams, store
            local mark
            for _, ch in ipairs(CHANNELS) do
                local caught = store.caughtUp[ch]
                if caught then self.baseline[ch] = { caught[1], caught[2] } end
                local epoch = Chat:NewestId(store, ch)
                if epoch and (not mark or epoch > mark) then mark = epoch end
            end
            self.loginMark = mark
            for _, ch in ipairs(CHANNELS) do
                if streams[ch] then
                    self.active[ch] = "backfill"
                    self.requestCount[ch] = 0
                    self:Step(ch)
                end
            end
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

-- For the "load older" control: a walk per channel whose archive does not reach the server's beginning yet.
function Chat:LoadOlder()
    if self.disabled or not self.started or not self:Eligible() then return end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and not self.active[ch] and not self.pending[ch] and not self.store.begin[ch] then
            self.active[ch], self.goal[ch], self.beyond[ch], self.olderCount[ch] = "older", nil, nil, 0
            self:Step(ch)
            if self.disabled then return end
        end
    end
end

-- The Chat page's status line: says something only while older messages are being fetched (or the archive is
-- off). Reaching the start of the server's history is not announced; the line just goes quiet.
function Chat:Status()
    if self.disabled or not self:Eligible() then return "Guild chat archive is off" end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] and (self.pending[ch] or self.queued[ch]) then return "Loading older messages\226\128\166" end
    end
    return ""
end

-- CLUB_MESSAGE_ADDED(clubId, streamId, messageId): a new message in a stream we archive.
function Chat:OnMessageAdded(clubId, streamId, messageId)
    if self.disabled or not self.started or not self:Eligible() then return end
    if clubId ~= self.clubId then return end
    for _, ch in ipairs(CHANNELS) do
        if self.streams[ch] ~= nil and self.streams[ch] == streamId then
            local ok, info = self:Call("GetMessageInfo", clubId, streamId, messageId)
            if ok and type(info) == "table" and self:Archive(ch, info) then self:Changed() end
            return
        end
    end
end

-- CLUB_MESSAGE_HISTORY_RECEIVED(clubId, streamId, ...): older messages arrived. The payload on WoW Forever is not
-- known beyond the first two arguments, so an unknown stream id means "look at every channel".
function Chat:OnHistory(clubId, streamId)
    if self.disabled or not self.started or not self:Eligible() then return end
    if clubId ~= nil and clubId ~= self.clubId then return end
    for _, ch in ipairs(CHANNELS) do
        local stream = self.streams[ch]
        if stream ~= nil and (streamId == nil or streamId == stream) then
            self.token[ch] = (self.token[ch] or 0) + 1
            self.pending[ch] = nil
            if self.active[ch] then
                -- A running walk reads in its next step.
                if not self.queued[ch] and not self.disabled then
                    self.queued[ch] = true
                    C_Timer.After(SETTLE, function() self:Step(ch) end)
                end
            else
                -- History nobody here asked for (the guild window scrolled, a late reply): read all of it.
                self:ReadDownloaded(ch, true)
                if self.disabled then return end
                local oldest = self:Oldest(ch)
                if oldest then
                    local ok, begin = self:Call("IsBeginningOfStream", self.clubId, stream, oldest)
                    if ok and begin and self.messageErrors == 0 then self.store.begin[ch] = true end
                end
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
        C_Timer.After(START_DELAY, function() Chat:Start() end)
    elseif event == "GUILD_ROSTER_UPDATE" then
        -- Scan.lua (loaded first) has read the roster by now: a promotion or a late roster after the login tries
        -- gave up can start capture without a /reload.
        if Chat.tried and not Chat.started and not Chat.disabled and Chat:Eligible() then Chat:Start() end
    elseif event == "CLUB_MESSAGE_ADDED" then
        Chat:OnMessageAdded(...)
    elseif event == "CLUB_MESSAGE_HISTORY_RECEIVED" then
        Chat:OnHistory(...)
    end
end)
