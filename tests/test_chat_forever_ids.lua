-- WoW Forever's C_Club message positions are 14-digit numbers (56989626967438 was seen in game), and the game's
-- string.format refuses them for %d. Every message failed to archive in 1.4.0, so these pin real-sized ids, keep
-- a session with unreadable messages from marking the archive complete, and re-walk 1.4.0 archives once.
local W = require("wow")
local KEY = "Test Guild - Test Realm"
local BASE = W.START - 100000
local CLUB, GUILD, OFFICER = 7, 1, 2
local POSITION = 56989626967438

local function messages(count)
    local out = W.clubMessages(GUILD, count, BASE + 1)
    for i, info in ipairs(out) do info.messageId.position = POSITION + i end
    return out
end

local function newClub(count)
    W.club = {
        id = CLUB,
        streams = { { streamId = GUILD, name = "Guild", streamType = 1 }, { streamId = OFFICER, name = "Officer", streamType = 2 } },
        server = { [GUILD] = messages(count), [OFFICER] = {} },
        downloaded = { [GUILD] = count, [OFFICER] = 0 },
    }
end

local function session(db)
    local GL = W.load({ db = db })
    W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    return GL
end

local function lines(text)
    local n = 0
    for _, line in ipairs(W.chat) do if string.find(line, text, 1, true) then n = n + 1 end end
    return n
end

test("the stub refuses %d beyond 32 bits the way the game does", function()
    local good, err = pcall(string.format, "%d", POSITION)
    ok(not good, "raised")
    ok(string.find(tostring(err), "integer overflow attempting to store 56989626967438", 1, true) ~= nil, "game's message")
    eq(string.format("%d", 2147483647), "2147483647", "32-bit values still format")
end)

test("a 14-digit position is stored, read back exactly and deduped", function()
    local GL = session()
    local store = GL.Chat:Store(KEY)
    local rec = { epoch = (BASE + 1) * 1e6, pos = POSITION, ch = "g", author = "Ooh Woo", text = "hi" }
    eq(GL.Chat:Add(store, rec), true, "added")
    eq(GL.Chat:Add(store, rec), false, "duplicate rejected")
    local got = GL.Chat:Query(store, {})
    eq(#got, 1, "one record")
    eq(got[1] and got[1].pos, POSITION, "position exact")
end)

test("messages with Forever-sized positions are archived with no read errors", function()
    newClub(5)
    local GL = session()
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    eq(GL.Chat:Count(GL.Chat:Store(KEY)), 5, "all archived")
    eq(lines("could not read"), 0, "no skipped messages")
end)

test("a session that skipped unreadable messages does not mark the archive complete", function()
    newClub(3)
    W.club.server[GUILD][2].author = setmetatable({}, { __index = function() error("unreadable author") end })
    local GL = session()
    GL.Chat:Start()
    W.runTimers()
    local store = GL.Chat:Store(KEY)
    eq(GL.Chat:Count(store), 2, "the readable ones are archived")
    eq(store.caughtUp.g, nil, "no catch-up mark over the skipped message")
    eq(store.begin.g, nil, "no start-of-history mark either")
end)

test("an archive saved by 1.4.0 is walked again once", function()
    local GL = session()
    local store = GL.Chat:Store(KEY)
    store.v = nil
    store.caughtUp.g = { (BASE + 3) * 1e6, 0 }
    store.begin.g = true
    GL = session(GL.db)
    store = GL.Chat:Store(KEY)
    eq(store.caughtUp.g, nil, "catch-up mark cleared")
    eq(store.begin.g, nil, "start-of-history mark cleared")
    store.caughtUp.g = { (BASE + 5) * 1e6, 0 }
    GL = session(GL.db)
    eq(GL.Chat:Store(KEY).caughtUp.g ~= nil, true, "only once")
end)

-- WoW Forever's C_Club.IsBeginningOfStream answers false even for the guild's very first message, so a walk that
-- trusted it asked for older history that does not exist until its request cap, showing "Loading older messages"
-- the whole time. A request that brings nothing older, a few times running, is the start of the stream.
local function drive()
    for _ = 1, 400 do
        local before = #W.clubRequests
        W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
        W.runTimers()
        if #W.clubRequests == before then return end
    end
end

test("a backfill ends at the stream's start when the game never says it is the beginning", function()
    newClub(250)
    W.club.downloaded[GUILD] = 100
    W.club.noBeginning = true
    local GL = session()
    W.clubRequests = {}
    GL.Chat:Start()
    drive()
    local store = GL.Chat:Store(KEY)
    eq(GL.Chat:Count(store), 250, "all archived")
    ok(#W.clubRequests <= 6, "stopped soon after the start (" .. #W.clubRequests .. " requests)")
    eq(store.begin.g, true, "start of history recorded")
    ok(store.caughtUp.g ~= nil, "caught up")
    eq(GL.Chat:Status(), "That's the start of the server's history", "status says so")
end)

test("load older stops asking once the stream's start is found that way", function()
    newClub(50)
    W.club.noBeginning = true
    local GL = session()
    GL.Chat:Start()
    drive()
    W.clubRequests = {}
    GL.Chat:LoadOlder()
    drive()
    eq(#W.clubRequests, 0, "no requests past the start")
    eq(GL.Chat:Status(), "That's the start of the server's history", "status")
end)
