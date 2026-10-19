--- Test Luakit startup with empty URIs and initial mode initialization.
--
-- @copyright 2026

local assert = require "luassert"
local test = require "tests.lib"

uris = {}
require "config.rc"

local window = require "window"
local settings = require "settings"

local T = {}

T.test_startup_empty_uris_creates_home_page_tab = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))

    -- Verify that empty uris argument resulted in exactly one tab
    assert.equal(1, #w.tabs, "Startup with empty uris should create exactly one tab")
    assert.is_not_nil(w.view, "Active view must exist")

    -- Verify initial mode is normal
    assert.equal("normal", w.mode.name, "Initial window mode must be normal")

    -- Verify immediate entry into follow mode functions properly
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("Follow:", w.ibar.prompt.text, "Prompt should indicate follow mode")

    -- Exit follow mode
    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name, "Window mode must return to normal")
end

T.test_window_new_without_args_opens_home_page = function ()
    test.wait_for_idle()
    local home_page = settings.get_setting("window.home_page")

    local w2 = window.new({})
    test.wait_for_idle()

    assert.equal(1, #w2.tabs, "New window should have 1 tab")
    assert.is_not_nil(w2.view, "New window view must exist")
    assert.equal(home_page, w2.view.uri, "New window must open home page URI")
    assert.equal("normal", w2.mode.name, "New window initial mode must be normal")

    -- Clean up window
    w2:close_win()
    test.wait_for_idle()
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
