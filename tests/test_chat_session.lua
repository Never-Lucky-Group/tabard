-- The Chat tab reads guild and officer chat from what the game holds this session (Chat.lua); nothing is saved.
-- At login each channel is topped up to about 250 messages; "Load all history" walks back to the start, which on
-- WoW Forever has to be found by requests that bring nothing older (IsBeginningOfStream answers false).
local W = require("wow")
local BASE = W.START - 100000
local CLUB, GUILD, OFFICER = 7, 1, 2

local function newClub(guildCount, downloaded, officerCount)
    local guild = W.clubMessages(GUILD, guildCount, BASE + 1)
    for i, info in ipairs(guild) do info.messageId.position = 56989626967438 + i end   -- Forever-sized positions
    W.club = {
        id = CLUB,
        streams = { { streamId = GUILD, name = "Guild", streamType = 1 }, { streamId = OFFICER, name = "Officer", streamType = 2 } },
        server = { [GUILD] = guild, [OFFICER] = W.clubMessages(OFFICER, officerCount or 0, BASE + 500, "Zev") },
        downloaded = { [GUILD] = downloaded or guildCount, [OFFICER] = officerCount or 0 },
        noBeginning = true,
    }
end

local function session(db, rankIndex)
    local GL = W.load({ db = db })
    W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = rankIndex or 0, level = 60, class = "MAGE" },
        { name = "Ooh Woo", rank = "R", rankIndex = 5, level = 60, class = "PRIEST" } })
    W.scan(GL)
    return GL
end

-- Fires the history event for both streams and runs timers until a round makes no new request.
local function drive()
    for _ = 1, 600 do
        local before = #W.clubRequests
        W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, GUILD)
        W.fire("CLUB_MESSAGE_HISTORY_RECEIVED", CLUB, OFFICER)
        W.runTimers()
        if #W.clubRequests == before then return end
    end
end

local function started(n, downloaded, officer, rankIndex)
    newClub(n, downloaded, officer)
    local GL = session(nil, rankIndex)
    W.clubRequests = {}
    GL.Chat:Start()
    drive()
    return GL
end

test("Start tops the guild channel up to 250 messages and no further", function()
    local GL = started(1000, 100)
    eq(#GL.Chat:Messages({ channels = { g = true } }), 300, "100 at login plus two batches")
    eq(#W.clubRequests, 2, "two requests")
    eq(GL.Chat:Loading(), false, "done")
    eq(GL.Chat:AllLoaded(), false, "older history not fetched")
    eq(GL.Chat:Status(), "", "status quiet")
end)

test("Load all history walks back to the start even though the game never says it is the beginning", function()
    local GL = started(1000, 100)
    W.clubRequests = {}
    GL.Chat:LoadAll()
    eq(GL.Chat:Loading(), true, "loading")
    eq(GL.Chat:Status(), "Loading older messages\226\128\166", "status while loading")
    drive()
    eq(#GL.Chat:Messages(), 1000, "everything")
    ok(#W.clubRequests <= 12, "stopped soon after the start (" .. #W.clubRequests .. " requests)")
    eq(GL.Chat:AllLoaded(), true, "all loaded")
    eq(GL.Chat:Status(), "", "status quiet afterwards")
    W.clubRequests = {}
    GL.Chat:LoadAll()
    drive()
    eq(#W.clubRequests, 0, "a second click asks for nothing")
end)

test("Messages merges both channels in time order, filters by channel, author and date, and skips destroyed ones", function()
    local GL = started(5, 5, 2)
    W.club.server[GUILD][3].destroyed = true
    local all = GL.Chat:Messages()
    eq(#all, 6, "4 guild + 2 officer")
    for i = 2, #all do ok(all[i - 1].epoch <= all[i].epoch, "in time order") end
    eq(all[1].text, "stream 1 message 1", "the text as the game gives it")
    eq(#GL.Chat:Messages({ channels = { o = true } }), 2, "officer only")
    eq(#GL.Chat:Messages({ authors = { Zev = true } }), 2, "by author")
    eq(#GL.Chat:Messages({ since = BASE + 500 }), 2, "by date")
end)

test("nothing about chat is saved, and 1.4.0's saved chat is removed", function()
    local GL = session({ chat = { ["Test Guild - Test Realm"] = { days = { ["20261107"] = "x" } } } })
    W.fire("PLAYER_LOGIN")
    eq(GL.db.chat, nil, "old saved chat gone")
    newClub(5)
    GL.Chat:Start()
    drive()
    eq(GL.db.chat, nil, "still nothing saved")
end)

test("a player below the sharing rank fetches nothing", function()
    local GL = started(1000, 100, 0, 3)
    eq(#W.clubRequests, 0, "no requests")
    eq(#GL.Chat:Messages(), 0, "nothing shown")
end)

test("a missing or failing C_Club raises nothing", function()
    newClub(5)
    local GL = session()
    _G.C_Club = nil
    W.clearChat()
    local good = pcall(GL.Chat.Start, GL.Chat)
    ok(good, "no error")
    eq(#W.chat, 0, "silent")
    newClub(5)
    GL = session()
    C_Club.GetMessageRanges = function() error("boom") end
    W.clearChat()
    GL.Chat:Start()
    W.runTimers()
    GL.Chat:LoadAll()
    W.runTimers()
    local lines = 0
    for _, line in ipairs(W.chat) do if string.find(line, "guild chat is off for this session", 1, true) then lines = lines + 1 end end
    eq(lines, 1, "one line")
    eq(#GL.Chat:Messages(), 0, "nothing shown")
end)
