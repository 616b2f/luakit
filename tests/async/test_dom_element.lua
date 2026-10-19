local test = require "tests.lib"
local assert = require "luassert"

-- Register test web module before window/webview initialization
local dom_wm = require_web_module("tests.async.dom_test_wm")

uris = { test.http_server() .. "test_follow.html" }
require "config.rc"

local window = require "window"

local T = {}

T.test_dom_element_properties_and_setters = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    test.wait_for_view(w.view)

    local result = nil
    local handler
    handler = function (_, res)
        result = res
        dom_wm:remove_signal("dom_tests_result", handler)
        test.continue()
    end
    dom_wm:add_signal("dom_tests_result", handler)

    dom_wm:emit_signal(w.view, "run_dom_tests")
    test.wait(5000)

    assert.is_not_nil(result, "timed out waiting for DOM tests response from web extension")
    assert.is_true(result.success, "DOM element tests failed: " .. tostring(result.error))
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
