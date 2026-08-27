local T = {}
local test = require "tests.lib"
local assert = require "luassert"

uris = { test.http_server() .. "hello_world.html" }
require "config.rc"

local window = require "window"

local initial_loaded = false
local function ensure_initial_page(w)
    test.wait_for_idle()
    if not initial_loaded then
        test.wait_for_view(w.view)
        initial_loaded = true
    end
end

T.test_reproduce_provisional_eval_js_error = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_initial_page(w)

    local error_logged = nil
    local function log_handler(time, level, group, msg)
        if level == "error" and msg:find("JavaScript context not available") then
            error_logged = msg
        end
    end
    msg.add_signal("log", log_handler)

    -- Opening a tab with an unroutable / pending URL triggers tab build and provisional load.
    -- While the network request is pending, the frame has no JavaScript context yet.
    -- update_favicon must not be called prematurely before status is "finished".
    local view = w:new_tab("http://192.0.2.1:9999/pending", { switch = true })

    -- Wait 500ms for any potential premature eval_js callback to return from web process
    test.delay(500)

    msg.remove_signal("log", log_handler)
    w:close_tab(view)

    -- Ensure no "JavaScript context not available" error was logged
    assert.is_nil(error_logged, "Reproduced bug: " .. tostring(error_logged))
end

T.test_tab_favicons_build_and_load = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_initial_page(w)

    assert.is_not_nil(w.tablist)
    assert.is_false(w.view.is_loading)
    assert.is_equal(test.http_server() .. "hello_world.html", w.view.uri)
end

T.test_tab_favicons_private_tab = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_initial_page(w)

    local view = w:new_tab("about:blank", { private = true, switch = true })
    assert.is_not_nil(view)
    assert.is_true(view.private)

    test.delay(100)
    w:close_tab(view)
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
