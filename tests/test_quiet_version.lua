-- The version we put on the wire carries an NL- label, so upstream Tabard copies (which cannot parse it) stay
-- quiet about it, and only a newer fork build raises the "available" notice on our side.
local W = require("wow")
local SEP = "\031"
local roster = {
    { name = "Zev", rank = "Guild Master", rankIndex = 0, level = 60, class = "MAGE" },
    { name = "Ooh Woo", rank = "Officer", rankIndex = 1, level = 60, class = "PRIEST", online = true },
}
local function setup()
    local GL = W.load()
    W.setRoster(roster)
    W.scan(GL)
    return GL
end
local function countAvailable()
    local n = 0
    for _, line in ipairs(W.chat) do if string.find(line, "is available", 1, true) then n = n + 1 end end
    return n
end
local function helloFrom(version)
    W.fire("CHAT_MSG_ADDON", "Tabard", table.concat({ "H", version, "0", "0", "2" }, SEP), "GUILD", "Ooh Woo")
end

test("a fork peer on a newer fork build raises the notice", function()
    local GL = setup()
    W.clearChat()
    helloFrom("NL-1.2.12")
    eq(GL.newerVersion, "1.2.12", "the plain number is kept")
    eq(countAvailable(), 1, "one notice line")
    ok(string.find(W.chat[#W.chat] or "", "Tabard 1.2.12 is available", 1, true) ~= nil, "the line names the plain version")
end)
test("an upstream peer on a higher plain version raises nothing", function()
    local GL = setup()
    W.clearChat()
    helloFrom("1.2.14")
    eq(GL.newerVersion, nil, "no newer version recorded")
    eq(countAvailable(), 0, "no notice line")
end)
test("a fork peer on an older or equal build raises nothing", function()
    local GL = setup()
    W.clearChat()
    helloFrom("NL-1.2.10")
    helloFrom("NL-1.2.11")
    eq(GL.newerVersion, nil, "no newer version recorded")
    eq(countAvailable(), 0, "no notice line")
end)
test("junk versions raise nothing", function()
    local GL = setup()
    W.clearChat()
    helloFrom("NL-")
    helloFrom("NL-abc")
    helloFrom("?")
    eq(GL.newerVersion, nil, "no newer version recorded")
    eq(countAvailable(), 0, "no notice line")
end)
test("our hello and usage carry the NL- label", function()
    local GL = setup()
    local sent = {}
    C_ChatInfo.SendAddonMessage = function(prefix, message, channel, target)
        sent[#sent + 1] = { prefix = prefix, message = message, channel = channel, target = target }
        return 0
    end
    C_ChatInfo.AreOutgoingAddonChatMessagesRestricted = function() return false end
    C_ChatInfo.InChatMessagingLockdown = function() return false end
    GL.Sync:Hello(true)
    W.tick(10)
    local hello
    for _, m in ipairs(sent) do if string.sub(m.message, 1, 1) == "H" then hello = m.message end end
    ok(hello ~= nil, "a hello went out")
    ok(hello and string.sub(hello, 1, #("H" .. SEP .. "NL-1.2.11" .. SEP)) == "H" .. SEP .. "NL-1.2.11" .. SEP, "hello carries NL-1.2.11")
    for _, m in ipairs(sent) do
        if string.sub(m.message, 1, 1) == "U" then
            eq(string.match(m.message, "^U" .. SEP .. "([^" .. SEP .. "]*)"), "NL-1.2.11", "usage carries NL-1.2.11")
        end
    end
end)
