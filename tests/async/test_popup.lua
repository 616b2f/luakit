--- Test webview popup and window.opener preservation.
--
-- @copyright 2026

local assert = require "luassert"
local test = require "tests.lib"

uris = { test.http_server() .. "test_follow.html" }
require "config.rc"

local window = require "window"
local settings = require "settings"

local T = {}

T.test_popup_window_opener_preserved = function ()
    settings.set_setting("webview.javascript_can_open_windows_automatically", true)
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    test.wait_for_view(w.view)

    local initial_tab_count = #w.tabs
    assert.equal(1, initial_tab_count)

    -- Trigger popup window via window.open
    w.view:eval_js("window.popup_ref = window.open('about:blank', '_blank');", { no_return = true })

    -- Wait for popup tab to be created
    test.wait_until(function ()
        return #w.tabs == initial_tab_count + 1
    end, 50, 4000)

    assert.equal(initial_tab_count + 1, #w.tabs)
    local popup_view = w.tabs[#w.tabs]
    test.wait_for_view(popup_view)

    -- Verify window.opener relationship is intact across related webviews
    local has_opener = false
    test.wait_until(function ()
        popup_view:eval_js("window.opener !== null && window.opener !== undefined", {
            callback = function (res)
                has_opener = res
                test.continue()
            end
        })
        test.wait(500)
        return has_opener == true
    end, 50, 4000)

    assert.is_true(has_opener, "window.opener must not be null in popup tab")

    -- Clean up popup tab
    w:close_tab()
    test.wait_for_idle()
    assert.equal(initial_tab_count, #w.tabs)
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
