-- The chat archive store: one string per local day, deduped, searchable, trimmed, and kept out of backups.
local W = require("wow")
local GL, store
local function setup()
    GL = W.load()
    store = GL.Chat:Store("Test Guild - Test Realm")
    return GL.Chat
end
local function rec(sec, pos, ch, author, text)
    return { epoch = sec * 1e6, pos = pos, ch = ch or "g", author = author, text = text }
end
-- The stub player resolves to "Zev Zev" (GL:PlayerName), so that is the roster name Eligible looks up.
local function dayKey(sec) return date("%Y%m%d", sec) end

test("epoch round-trips through Encode/Decode without an exponent", function()
    local Chat = setup()
    local line = Chat.Encode({ epoch = 1763000000123456, pos = 3, ch = "o", author = "Zev", text = "hi" })
    ok(string.find(line, "1763000000123456", 1, true) ~= nil, "full digits present")
    ok(string.find(line, "e+", 1, true) == nil, "no exponent")
    local r = Chat.Decode(line)
    eq(r.epoch, 1763000000123456, "epoch")
    eq(r.pos, 3, "pos")
    eq(r.ch, "o", "channel")
    eq(r.author, "Zev", "author")
    eq(r.text, "hi", "text")
end)

test("records in one local day share one string ordered by epoch and pos", function()
    local Chat = setup()
    local t = W.START
    ok(Chat:Add(store, rec(t + 30, 1, "g", "A", "third")), "add")
    ok(Chat:Add(store, rec(t, 2, "g", "B", "second")), "add earlier")
    ok(Chat:Add(store, rec(t, 1, "g", "C", "first")), "add same epoch lower pos")
    local n = 0
    for _ in pairs(store.days) do n = n + 1 end
    eq(n, 1, "one day string")
    ok(store.days[dayKey(t)] ~= nil, "keyed by local day")
    local got = Chat:Query(store, {})
    eq(#got, 3, "three records")
    eq(got[1].text, "first", "order 1")
    eq(got[2].text, "second", "order 2")
    eq(got[3].text, "third", "order 3")
end)

test("a duplicate add is rejected, including into an older populated day", function()
    local Chat = setup()
    local old = W.START - 5 * 86400
    ok(Chat:Add(store, rec(old, 1, "g", "A", "old")), "old add")
    ok(Chat:Add(store, rec(old + 10, 1, "g", "A", "old2")), "old add 2")
    ok(Chat:Add(store, rec(W.START, 1, "g", "A", "new")), "new add")
    eq(Chat:Add(store, rec(old + 10, 1, "g", "A", "old2")), false, "duplicate in old day")
    eq(Chat:Add(store, rec(W.START, 1, "g", "A", "new")), false, "duplicate in newest day")
    eq(Chat:Count(store), 3, "count unchanged")
    eq(Chat:Add(store, { ch = "g", pos = 1, text = "x" }), false, "missing epoch is invalid")
    eq(Chat:Add(store, { epoch = 1e6, pos = 1, text = "x" }), false, "missing channel is invalid")
end)

test("separators are stripped, empty text kept, nil author becomes ?", function()
    local Chat = setup()
    ok(Chat:Add(store, rec(W.START, 1, "g", "Zev\030x", "a\031b\030c")), "add")
    ok(Chat:Add(store, rec(W.START, 2, "g", nil, "")), "empty text and nil author")
    local got = Chat:Query(store, {})
    eq(#got, 2, "both stored")
    eq(got[1].author, "Zevx", "author stripped")
    eq(got[1].text, "abc", "text stripped")
    eq(got[2].author, "?", "nil author")
    eq(got[2].text, "", "empty text")
end)

test("Query filters by text, authors, channels and since, alone and combined", function()
    local Chat = setup()
    local d = 86400
    Chat:Add(store, rec(W.START - 3 * d, 1, "g", "Zev", "Raid tonight"))
    Chat:Add(store, rec(W.START - 1 * d, 1, "o", "Ooh", "raid prep officers"))
    Chat:Add(store, rec(W.START, 1, "g", "Ooh", "hello there"))
    Chat:Add(store, rec(W.START + 10, 2, "g", "Zev", "RAID again"))
    eq(#Chat:Query(store, {}), 4, "no filter")
    eq(#Chat:Query(store, { text = "raid" }), 3, "text case-insensitive")
    eq(#Chat:Query(store, { text = "r.id" }), 0, "text is plain, not a pattern")
    eq(#Chat:Query(store, { authors = { Zev = true } }), 2, "authors")
    eq(#Chat:Query(store, { channels = { o = true } }), 1, "officer channel")
    eq(#Chat:Query(store, { channels = { g = true } }), 3, "guild channel")
    eq(#Chat:Query(store, { since = W.START - 2 * d }), 3, "since")
    local got = Chat:Query(store, { text = "raid", authors = { Zev = true }, since = W.START - 2 * d })
    eq(#got, 1, "combined")
    eq(got[1].text, "RAID again", "combined result")
    local all = Chat:Query(store, { text = "raid" })
    ok(all[1].epoch < all[2].epoch and all[2].epoch < all[3].epoch, "time order")
end)

test("Trim drops only days older than keepDays, and does nothing for 0", function()
    local Chat = setup()
    local d = 86400
    Chat:Add(store, rec(W.START - 40 * d, 1, "g", "A", "ancient"))
    Chat:Add(store, rec(W.START - 40 * d + 5, 1, "g", "A", "ancient2"))
    Chat:Add(store, rec(W.START - 10 * d, 1, "g", "A", "recent"))
    Chat:Add(store, rec(W.START, 1, "g", "A", "today"))
    eq(Chat:Trim(store, 0, W.START), 0, "0 keeps all")
    eq(Chat:Trim(store, nil, W.START), 0, "nil keeps all")
    eq(Chat:Count(store), 4, "nothing lost")
    eq(Chat:Trim(store, 30, W.START), 2, "removed count")
    eq(Chat:Count(store), 2, "remaining")
    eq(Chat:Add(store, rec(W.START - 40 * d, 1, "g", "A", "ancient")), true, "trimmed day dedupe cache was reset")
end)

test("Count, Bytes and NewestId report the archive", function()
    local Chat = setup()
    eq(Chat:NewestId(store, "g"), nil, "empty newest")
    Chat:Add(store, rec(W.START - 86400, 4, "g", "A", "x"))
    Chat:Add(store, rec(W.START, 7, "g", "A", "y"))
    Chat:Add(store, rec(W.START + 5, 9, "o", "A", "z"))
    local e, p = Chat:NewestId(store, "g")
    eq(e, W.START * 1e6, "newest guild epoch")
    eq(p, 7, "newest guild pos")
    local oe, op = Chat:NewestId(store, "o")
    eq(oe, (W.START + 5) * 1e6, "newest officer epoch")
    eq(op, 9, "newest officer pos")
    local total = 0
    for _, s in pairs(store.days) do total = total + #s end
    eq(Chat:Bytes(store), total, "bytes")
    ok(total > 0, "nonzero")
end)

test("Eligible follows rank, the setting and roster membership", function()
    local function with(rankIndex)
        local g = W.load()
        W.setRoster({ { name = "Zev Zev", rank = "R", rankIndex = rankIndex, level = 60, class = "MAGE" } })
        W.scan(g)
        return g
    end
    local g = with(0)
    eq(g.Chat:Eligible(), true, "rank 0")
    g = with(1)
    eq(g.Chat:Eligible(), true, "rank 1")
    g = with(2)
    eq(g.Chat:Eligible(), false, "rank 2")
    g = with(1)
    g.settings.chatArchive = false
    eq(g.Chat:Eligible(), false, "setting off")
    g = W.load()
    W.setRoster({ { name = "Someone", rank = "R", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(g)
    eq(g.Chat:Eligible(), false, "player not in roster")
    g = with(2)
    g.settings.syncMinRank = 2
    eq(g.Chat:Eligible(), true, "raised syncMinRank admits rank 2")
end)

test("a backup never carries chat data", function()
    local Chat = setup()
    W.setRoster({ { name = "Zev Zev", rank = "GM", rankIndex = 0, level = 60, class = "MAGE" } })
    W.scan(GL)
    Chat:Add(store, rec(W.START, 1, "g", "A", "keep me out"))
    ok(GL:Backup(GL:Guild(), "t"), "backup taken")
    eq(GL.db.backup.guild.chat, nil, "no chat in the backup guild")
    local function hasDays(t, seen)
        seen = seen or {}
        if type(t) ~= "table" or seen[t] then return false end
        seen[t] = true
        if t.days then return true end
        for _, v in pairs(t) do if hasDays(v, seen) then return true end end
        return false
    end
    eq(hasDays(GL.db.backup), false, "no days tables in the backup")
    eq(Chat:Count(GL.db.chat["Test Guild - Test Realm"]), 1, "live chat intact")
end)

test("Trim that drops days forgets that the archive reached the server's beginning", function()
    local Chat = setup()
    Chat:Add(store, rec(W.START - 400 * 86400, 1, "g", "A", "old"))
    Chat:Add(store, rec(W.START, 1, "g", "A", "new"))
    store.begin.g = true
    Chat:Trim(store, 30, W.START)
    eq(store.begin.g, nil, "begin cleared")
    eq(Chat:OldestId(store, "g"), W.START * 1e6, "OldestId is the oldest record left")
end)
