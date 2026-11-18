-- Housekeeping, size and tidy reports, and the usage code for the Chat page: the chat archive's share of each.
local W = require("wow")
local KEY = "Test Guild - Test Realm"
local DAY = 86400

local function setup(db)
    local GL = W.load({ db = db })
    W.setRoster({ { name = "Zev Zev", rank = "Guild Master", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    GL:Guild()
    return GL
end

local function rec(sec, pos, text)
    return { epoch = sec * 1e6, pos = pos or 1, ch = "g", author = "Ann", text = text or "hi" }
end

local function linesWith(text)
    local n = 0
    for _, line in ipairs(W.chat) do if string.find(line, text, 1, true) then n = n + 1 end end
    return n
end

test("housekeeping trims chat older than chatKeepDays", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    ok(GL.Chat:Add(store, rec(W.START - 400 * DAY, 1, "old")), "old message added")
    ok(GL.Chat:Add(store, rec(W.START - 10 * DAY, 1, "recent")), "recent message added")
    GL.settings.chatKeepDays = 365
    local report = GL:Housekeeping(GL:Guild(), W.START)
    eq(report.chat, 1, "one message removed")
    eq(GL.Chat:Count(store), 1, "one message remains")
    eq(GL.Chat:Query(store, {})[1].text, "recent", "the recent one is kept")
end)

test("housekeeping keeps all chat by default", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    ok(GL.Chat:Add(store, rec(W.START - 4000 * DAY, 1, "ancient")), "ancient message added")
    local report = GL:Housekeeping(GL:Guild(), W.START)
    eq(report.chat, 0, "nothing removed")
    eq(GL.Chat:Count(store), 1, "message kept")
end)

test("housekeeping does not create an archive for a guild that never had one", function()
    local GL = setup()
    local report = GL:Housekeeping(GL:Guild(), W.START)
    eq(report.chat, 0, "nothing removed")
    eq(GL.db.chat and GL.db.chat[KEY], nil, "no archive created")
end)

test("size command reports the chat archive", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    GL.Chat:Add(store, rec(W.START, 1, "one"))
    GL.Chat:Add(store, rec(W.START, 2, "two"))
    W.clearChat()
    GL:KeepCommand("")
    ok(linesWith("guild chat: 2 messages") == 1, "size line names the chat count")
    ok(linesWith(" KB)") == 1, "size line gives kilobytes")
end)

test("tidy command reports the chat archive", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    GL.Chat:Add(store, rec(W.START, 1, "one"))
    W.clearChat()
    GL:KeepCommand("tidy")
    ok(linesWith("guild chat: 1 messages") == 1, "tidy line names the chat count")
end)

test("size command says nothing about chat when there is no archive", function()
    local GL = setup()
    W.clearChat()
    GL:KeepCommand("")
    eq(linesWith("guild chat:"), 0, "no chat line")
end)

test("login housekeeping prints when only chat was trimmed, and names the chat count", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    GL.Chat:Add(store, rec(W.START - 400 * DAY, 1, "old"))
    GL.settings.chatKeepDays = 365
    W.clearChat()
    W.fire("PLAYER_LOGIN")
    W.runTimers()
    eq(linesWith("housekeeping:"), 1, "one housekeeping line")
    eq(linesWith("1 old guild chat messages"), 1, "the line names the chat count")
end)

test("chat page has a usage code", function()
    local GL = setup()
    GL.Usage:Page("chat")
    ok(string.find(GL.Usage:Wire() or "", "ch1", 1, true) ~= nil, "the chat page is counted under ch")
end)

test("tidy command says how many chat messages it dropped", function()
    local GL = setup()
    local store = GL.Chat:Store(KEY)
    GL.Chat:Add(store, rec(W.START - 400 * DAY, 1, "old"))
    GL.Chat:Add(store, rec(W.START, 1, "new"))
    GL.settings.chatKeepDays = 365
    W.clearChat()
    GL:KeepCommand("tidy")
    eq(linesWith("and 1 guild chat messages"), 1, "the tidy line names the dropped chat count")
end)
