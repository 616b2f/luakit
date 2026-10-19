--- Test internal luakit:// chrome pages.
--
-- @copyright 2026

local assert = require "luassert"
local test = require "tests.lib"

uris = { "about:blank" }
require "config.rc"

local window = require "window"

local function verify_chrome_page(w, uri, expected_title_part)
    w:navigate(uri)
    test.wait_for_view(w.view)
    assert.equal(uri, w.view.uri)

    local title = nil
    w.view:eval_js("document.title", {
        callback = function (res)
            title = res
            test.continue()
        end
    })
    test.wait(2000)
    assert.is_string(title, "document.title must be a string for " .. uri)
    if expected_title_part then
        local found = title:lower():find(expected_title_part:lower(), 1, true)
        assert.is_not_nil(found, string.format("title '%s' did not contain '%s'", title, expected_title_part))
    end

    local body_exists = false
    w.view:eval_js("document.body !== null", {
        callback = function (res)
            body_exists = res
            test.continue()
        end
    })
    test.wait(2000)
    assert.is_true(body_exists, "document.body must exist for " .. uri)
end

local T = {}

T.test_chrome_settings_page = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    verify_chrome_page(w, "luakit://settings/", "settings")
end

T.test_chrome_bookmarks_page = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    verify_chrome_page(w, "luakit://bookmarks/", "bookmarks")
end

T.test_chrome_history_page = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    verify_chrome_page(w, "luakit://history/", "history")
end

T.test_chrome_help_and_binds_pages = function ()
    test.wait_for_idle()
    local w = assert(select(2, next(window.bywidget)))
    verify_chrome_page(w, "luakit://help/", "help")
    verify_chrome_page(w, "luakit://binds/", "bindings")
    verify_chrome_page(w, "luakit://downloads/", "downloads")
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
