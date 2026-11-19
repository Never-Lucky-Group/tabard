-- The Chat page lives in UI.lua, whose window cannot be built offline. Loaded by hand like test_card_combat.lua.
local W = require("wow")
local function withUI()
    local GL = W.load()
    assert(loadfile("UI.lua"))("Tabard", GL)
    return GL
end
test("the chat refresh hook exists and is harmless without a window", function()
    local GL = withUI()
    eq(type(GL.OnChatChanged), "function", "defined by UI.lua")
    local good, err = pcall(GL.OnChatChanged, GL)
    ok(good, "no window: " .. tostring(err))
end)
test("the ledger hook is harmless without a window", function()
    local GL = withUI()
    local good, err = pcall(GL.OnLedgerChanged, GL)
    ok(good, "ledger hook, no window: " .. tostring(err))
end)
