-- Guild chat capture from C_Club: downloaded, live and backfilled messages, resumable backfill, and safety.
local W = require("wow")
local KEY = "Test Guild - Test Realm"
local BASE = W.START - 100000   -- server message i is at second BASE + i
local CLUB, GUILD, OFFICER = 7, 1, 2

local function newClub(guildCount, downloaded, officerCount)
    W.club = {
        id = CLUB,
        streams = { { streamId = GUILD, name = "Guild", streamType = 1 }, { streamId = OFFICER, name = "Officer", streamType = 2 } },
        server = { [GUILD] = W.clubMessages(GUILD, guildCount, BASE + 1), [OFFICER] = W.clubMessages(OFFICER, officerCount or 0, BASE + 500, "Zev") },
        downloaded = { [GUILD] = downloaded or guildCount, [OFFICER] = officerCount or 0 },
    }
end

-- A session on `db` (nil = first run) with the player at `rankIndex` in the roster.
local function session(db, rankIndex)
    local GL = W.load({ db = db })
    W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = rankIndex or 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    return GL
end

local function guildStore(GL) return GL.Chat:Store(KEY) end
local function lines(text)
    local n = 0
    for _, line in ipairs(W.chat) do if string.find(line, text, 1, true) then n = n + 1 end end
    return n
end

-- Fires the history event for both streams and runs timers until a round makes no new request.
local function drive()
    for _ = 1, 20 do
        local before = #W.clubRequests
        W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
        W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, OFFICER)
        W.runTimers()
        if #W.clubRequests == before then return end
    end
end

-- Puts messages 1..n of the stub's guild stream into the archive the way a finished earlier session would.
local function prefill(GL, n)
    local store = guildStore(GL)
    for i = 1, n do
        local info = W.club.server[GUILD][i]
        GL.Chat:Add(store, { epoch = info.messageId.epoch, pos = 0, ch = "g", author = "Ooh", text = info.content })
    end
    store.caughtUp.g = { GL.Chat:NewestId(store, "g") }
    return store
end

local function noMissing(GL, n)
    local got = GL.Chat:Query(guildStore(GL), { channels = { g = true } })
    eq(#got, n, "record count")
    for i, rec in ipairs(got) do
        if rec.epoch ~= (BASE + i) * 1e6 then ok(false, "hole or misorder at message " .. i) return end
    end
    ok(true, "ids contiguous")
end

test("downloaded guild messages are archived on Start", function()
    newClub(3)
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 3, "three archived")
    eq(#W.clubRequests, 0, "nothing older to ask for")
    eq(GL.Chat:Query(guildStore(GL), {})[1].author, "Ooh Woo", "author kept")
end)

test("a live CLUB_MESSAGE_ADDED is archived once", function()
    newClub(3)
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    local info = W.clubMessages(GUILD, 1, BASE + 50, "Ooh Woo-Realm")[1]
    W.clubPost(GUILD, info)
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    eq(GL.Chat:Count(guildStore(GL)), 4, "archived")
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    eq(GL.Chat:Count(guildStore(GL)), 4, "second event adds nothing")
    eq(GL.Chat:Query(guildStore(GL), {})[4].author, "Ooh Woo", "realm stripped")
end)

test("an empty archive backfills to the start of the stream and sets newest", function()
    newClub(250, 100)
    local GL = session()
    GL.Chat:Start()
    eq(guildStore(GL).caughtUp.g, nil, "caughtUp unset until the backfill completes")
    drive()
    noMissing(GL, 250)
    eq(#W.clubRequests, 2, "two requests reached the start")
    local e = GL.Chat:NewestId(guildStore(GL), "g")
    eq(e, (BASE + 250) * 1e6, "newest is the newest message")
    eq(guildStore(GL).caughtUp.g[1], e, "caughtUp.g set on completion")
    eq(GL.Chat:Status(), "", "status")
end)

test("backfill stops once the downloaded range reaches the archived newest", function()
    newClub(250, 100)
    local GL = session()
    prefill(GL, 100)
    local db = GL.db
    GL = session(db)
    GL.Chat:Start()
    drive()
    eq(#W.clubRequests, 1, "one request was enough")
    noMissing(GL, 250)
    local store = guildStore(GL)
    eq(store.caughtUp.g[1], (BASE + 250) * 1e6, "caughtUp advanced on completion")
    eq(store.caughtUp.g[1], (GL.Chat:NewestId(store, "g")), "caughtUp equals NewestId")
    local info = W.clubMessages(GUILD, 1, BASE + 900)[1]
    W.clubPost(GUILD, info)
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    eq(store.newest.g[1], (BASE + 900) * 1e6, "live message advances newest")
    eq(store.caughtUp.g[1], (BASE + 250) * 1e6, "live message leaves caughtUp alone")
    eq(GL.Chat:Status(), "", "not the start of history")
end)

test("an interrupted backfill leaves newest alone and the next session fills the gap", function()
    newClub(250, 100)
    local GL = session()
    prefill(GL, 100)
    local db = GL.db
    GL = session(db)
    GL.Chat:Start()
    eq(#W.clubRequests, 1, "one request made")
    eq(guildStore(GL).caughtUp.g[1], (BASE + 100) * 1e6, "caughtUp unchanged")
    -- a new session: the client has only the newest 100 again
    W.club.downloaded[GUILD] = 100
    GL = session(db)
    eq(guildStore(GL).caughtUp.g[1], (BASE + 100) * 1e6, "caughtUp still unchanged")
    GL.Chat:Start()
    drive()
    noMissing(GL, 250)
end)

test("officer messages are archived with ch o", function()
    newClub(2, 2, 4)
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    local o = GL.Chat:Query(guildStore(GL), { channels = { o = true } })
    eq(#o, 4, "officer records")
    eq(o[1].ch, "o", "channel")
    eq(#GL.Chat:Query(guildStore(GL), { channels = { g = true } }), 2, "guild records separate")
end)

test("destroyed messages are skipped", function()
    newClub(3)
    W.club.server[GUILD][2].destroyed = true
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    local got = GL.Chat:Query(guildStore(GL), {})
    eq(#got, 2, "two kept")
    ok(string.find(got[2].text, "message 3", 1, true) ~= nil, "the destroyed one is the missing one")
end)

test("a player below the rank bar makes no requests and archives nothing", function()
    newClub(250, 100)
    local GL = session(nil, 3)
    GL.Chat:Start()
    W.runTimers()
    drive()
    eq(#W.clubRequests, 0, "no requests")
    eq(GL.Chat:Count(guildStore(GL)), 0, "nothing archived")
    eq(GL.Chat:Status(), "Guild chat archive is off", "status")
end)

test("Start retries every 10 seconds, six times, until the roster makes the player eligible", function()
    newClub(3)
    local GL = W.load()
    GL.Chat:Start()
    W.runTimers()   -- runs every retry back to back: still not eligible, so nothing archived
    eq(GL.Chat:Count(guildStore(GL)), 0, "gave up")
    GL = W.load()
    GL.Chat:Start()
    W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 3, "a retry found the player eligible")
end)

test("without C_Club nothing raises and nothing prints", function()
    newClub(3)
    local GL = session()
    _G.C_Club = nil
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, { epoch = 1, position = 0 })
    W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
    W.runTimers()
    GL.Chat:LoadOlder()
    eq(#W.chat, 0, "no chat line")
    eq(GL.Chat.disabled, true, "capture off")
    eq(GL.Chat:Status(), "Guild chat archive is off", "status")
end)

test("a raising C_Club call turns capture off with exactly one line", function()
    newClub(3)
    local GL = session()
    C_Club.GetMessagesInRange = function() error("boom") end
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    GL.Chat:Start()
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, { epoch = 1, position = 0 })
    W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
    W.runTimers()
    eq(lines("guild chat archive is off for this session"), 1, "one line")
    eq(GL.Chat:Count(guildStore(GL)), 0, "nothing archived")
end)

test("a message that cannot be converted is skipped and reported once", function()
    newClub(3)
    local broken = setmetatable({}, { __index = function() error("unreadable author") end })
    W.club.server[GUILD][1].author = broken
    W.club.server[GUILD][2].author = broken
    local GL = session()
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 1, "the good one is archived")
    eq(#W.chat, 1, "one line for two bad messages")
    ok(not GL.Chat.disabled, "capture stays on")
end)

test("LoadOlder asks for older messages and the reply is archived", function()
    newClub(250, 100)
    local GL = session()
    prefill(GL, 100)
    GL = session(GL.db)
    GL.Chat:Start()
    drive()
    local requests = #W.clubRequests
    GL.Chat:LoadOlder()
    eq(#W.clubRequests, requests + 1, "one more request")
    eq(GL.Chat:Status(), "Loading older messages\226\128\166", "pending status")
    drive()
    noMissing(GL, 250)
    GL.Chat:LoadOlder()
    eq(#W.clubRequests, requests + 1, "nothing more once at the start")
    eq(GL.Chat:Status(), "", "status")
end)

test("loginMark is the newest archived epoch before this session's reads", function()
    newClub(250, 100)
    local GL = session()
    GL.Chat:Start()
    eq(GL.Chat.loginMark, nil, "empty archive")
    prefill(GL, 100)
    local db = GL.db
    GL = session(db)
    GL.Chat:Start()
    eq(GL.Chat.loginMark, (BASE + 250) * 1e6, "true newest of the earlier archive")
end)

test("GL:OnChatChanged is called once per second at most", function()
    newClub(3)
    local GL = session()
    local calls = 0
    function GL:OnChatChanged() calls = calls + 1 end
    GL.Chat:Start()
    local info = W.clubMessages(GUILD, 1, BASE + 50)[1]
    W.clubPost(GUILD, info)
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    eq(calls, 0, "deferred")
    W.runTimers()
    eq(calls, 1, "coalesced into one call")
end)

test("capture stops when the player is no longer eligible after Start", function()
    newClub(3)
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    GL.settings.chatArchive = false
    local info = W.clubMessages(GUILD, 1, BASE + 50)[1]
    W.clubPost(GUILD, info)
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
    GL.Chat:LoadOlder()
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 3, "nothing new archived")
    eq(#W.clubRequests, 0, "no requests")
end)

test("a backfill whose history event never arrives still archives everything before completing", function()
    newClub(250, 100)
    local GL = session()
    GL.Chat:Start()
    -- no history event is ever fired: only the watchdog drives the backfill
    W.runTimers()
    noMissing(GL, 250)
    eq(guildStore(GL).caughtUp.g[1], (BASE + 250) * 1e6, "caughtUp set after everything is archived")
end)

-- Archives messages i..j of the stub's guild stream and marks them caught up, like a finished earlier session.
local function prefillRange(GL, i, j)
    local store = guildStore(GL)
    for k = i, j do
        local info = W.club.server[GUILD][k]
        GL.Chat:Add(store, { epoch = info.messageId.epoch, pos = 0, ch = "g", author = "Ooh", text = info.content })
    end
    store.caughtUp.g = { GL.Chat:NewestId(store, "g") }
    return store
end

test("each backfill step reads only the slice the last request added", function()
    newClub(1000, 100)
    local GL = session()
    local real = C_Club.GetMessagesInRange
    local reads = {}
    C_Club.GetMessagesInRange = function(...)
        local out = real(...)
        reads[#reads + 1] = #out
        return out
    end
    GL.Chat:Start()
    W.runTimers()   -- the watchdog drives every step; no history event, so every read is a step's read
    noMissing(GL, 1000)
    eq(reads[1], 100, "the first step reads everything downloaded")
    ok(#reads >= 10, "one read per step (" .. #reads .. ")")
    local most = 0
    for i = 2, #reads do if reads[i] > most then most = reads[i] end end
    ok(most <= 101, "later steps read only the new hundred and the previous oldest (at most " .. most .. ")")
end)

test("a backfill that reaches the request cap records how far it got, and the next session stops there", function()
    newClub(400, 100)
    local GL = session()
    -- a server that sends one message per request, so 200 requests do not reach the start
    local real = C_Club.RequestMoreMessagesBefore
    C_Club.RequestMoreMessagesBefore = function(c, s, m) return real(c, s, m, 1) end
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    eq(#W.clubRequests, 200, "requests stop at the cap")
    local store = guildStore(GL)
    eq(GL.Chat:Count(store), 300, "everything downloaded is archived")
    ok(store.caughtUp.g ~= nil and store.caughtUp.g[1] == (BASE + 400) * 1e6, "caughtUp set at the cap")
    eq(GL.Chat.active.g, nil, "the backfill stopped")
    eq(lines("guild chat archive:"), 1, "one line says where the archive starts")
    W.club.downloaded[GUILD] = 100
    GL = session(GL.db)
    GL.Chat:Start()
    W.runTimers()
    eq(#W.clubRequests, 0, "the next session's backfill stops at the recorded target")
end)

test("reaching the start of the server's history is saved, and LoadOlder asks for nothing afterwards", function()
    newClub(250, 100)
    local GL = session()
    GL.Chat:Start()
    drive()
    eq(guildStore(GL).begin.g, true, "begin saved")
    W.club.downloaded[GUILD] = 100
    GL = session(GL.db)
    GL.Chat:Start()
    W.runTimers()
    eq(#W.clubRequests, 0, "nothing to backfill")
    GL.Chat:LoadOlder()
    eq(#W.clubRequests, 0, "LoadOlder made no request")
    eq(GL.Chat:Status(), "", "status at once")
end)

test("LoadOlder walks past what the archive already has, then adds one batch of older messages", function()
    newClub(1000, 100)
    local GL = session()
    prefillRange(GL, 301, 1000)
    GL = session(GL.db)
    GL.Chat:Start()
    W.runTimers()
    eq(#W.clubRequests, 0, "the archive already covers what is downloaded")
    eq(GL.Chat:Status(), "", "nothing loading yet")
    GL.Chat:LoadOlder()
    eq(GL.Chat:Status(), "Loading older messages\226\128\166", "loading while the walk runs")
    drive()
    eq(#W.clubRequests, 7, "six requests reach the archive's oldest, one more fetches the batch beyond it")
    local got = GL.Chat:Query(guildStore(GL), { channels = { g = true } })
    eq(#got, 800, "one batch of older messages added")
    eq(got[1].epoch, (BASE + 201) * 1e6, "the archive now starts a hundred earlier")
    eq(GL.Chat:Status(), "", "not loading, not at the start")
    GL.Chat:LoadOlder()
    drive()
    eq(#W.clubRequests, 8, "the next LoadOlder is one request")
    eq(GL.Chat:Count(guildStore(GL)), 900, "and one more batch")
end)

test("nothing downloaded yet at Start is not the start of history: the step looks again later", function()
    newClub(250, 0)
    local GL = session()
    GL.Chat:Start()
    eq(guildStore(GL).begin.g, nil, "begin not saved")
    W.club.downloaded[GUILD] = 100   -- the client's own first fetch lands
    W.runTimers()
    noMissing(GL, 250)
    eq(guildStore(GL).begin.g, true, "begin saved once really reached")
end)

test("a stream that stays empty is looked at a bounded number of times", function()
    newClub(250, 0)
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    eq(#W.clubRequests, 0, "no requests")
    eq(GL.Chat.active.g, nil, "gave up")
    eq(guildStore(GL).begin.g, nil, "begin not saved")
    eq(guildStore(GL).caughtUp.g, nil, "caughtUp not set")
end)

test("a roster scan that makes the player eligible after Start gave up starts capture", function()
    newClub(3)
    local GL = session(nil, 3)
    GL.Chat:Start()
    W.runTimers()
    eq(GL.Chat.started, false, "below the bar: not started")
    W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    eq(GL.Chat.started, true, "the promotion started capture")
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 3, "archived")
end)

test("a second Start, or a roster scan, while a backfill runs changes nothing", function()
    newClub(250, 100)
    local GL = session()
    GL.Chat:Start()
    eq(#W.clubRequests, 1, "one request")
    GL.Chat:Start()
    W.scan(GL)
    eq(#W.clubRequests, 1, "still one request")
end)

test("with two downloaded ranges the backfill walks back from the one holding the newest message", function()
    newClub(250, 100)
    local GL = session()
    local list = W.club.server[GUILD]
    C_Club.GetMessageRanges = function(c, s)
        if s ~= GUILD then return {} end
        return { { oldestMessageId = list[1].messageId, newestMessageId = list[50].messageId },
            { oldestMessageId = list[151].messageId, newestMessageId = list[250].messageId } }
    end
    GL.Chat:Start()
    eq(#W.clubRequests, 1, "one request")
    eq(W.clubRequests[1].messageId.epoch, list[151].messageId.epoch, "asked from the newest range's oldest")
    eq(guildStore(GL).caughtUp.g, nil, "not complete over the gap")
end)

test("a malformed range entry is skipped without an error", function()
    newClub(3)
    local GL = session()
    local real = C_Club.GetMessageRanges
    C_Club.GetMessageRanges = function(...)
        local out = real(...)
        table.insert(out, 1, 42)
        return out
    end
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    eq(GL.Chat:Count(guildStore(GL)), 3, "the good range is archived")
    ok(not GL.Chat.disabled, "capture stays on")
    eq(#W.chat, 0, "nothing printed")
end)

test("GL:OnChatChanged is told the oldest message archived since the last call", function()
    newClub(3)
    local GL = session()
    local got = {}
    function GL:OnChatChanged(from) got[#got + 1] = from or false end
    GL.Chat:Start()
    W.runTimers()
    eq(got[1], (BASE + 1) * 1e6, "the downloaded read starts at message 1")
    local info = W.clubMessages(GUILD, 1, BASE + 50)[1]
    W.clubPost(GUILD, info)
    W.fire("CLUB_MESSAGE_ADDED", CLUB, GUILD, info.messageId)
    W.runTimers()
    eq(got[2], (BASE + 50) * 1e6, "a live message reports itself")
end)

test("GL:OnChatStatus is called when a walk ends, so the status line does not stay on loading", function()
    newClub(250, 100)
    local GL = session()
    prefill(GL, 100)
    GL = session(GL.db)
    GL.Chat:Start()
    drive()
    local calls = 0
    function GL:OnChatStatus() calls = calls + 1 end
    GL.Chat:LoadOlder()   -- the empty officer stream's walk ends at once; the guild walk is still running
    local before = calls
    eq(GL.Chat:Status(), "Loading older messages\226\128\166", "the guild walk runs")
    drive()
    ok(calls > before, "called when the guild walk ended")
    eq(GL.Chat:Status(), "", "and the status has moved on")
end)
