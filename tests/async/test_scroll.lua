--- Test page scrolling.
--
-- @copyright 2017 Aidan Holm <aidanholm@gmail.com>

local T = {}
local test = require "tests.lib"
local assert = require "luassert"

uris = { test.http_server() .. "scroll.html" }
require "config.rc"

local window = require "window"
local w = assert(select(2, next(window.bywidget)))

local initial_loaded = false
local function ensure_initial_page()
    test.wait_for_idle()
    if not initial_loaded then
        test.wait_for_view(w.view)
        initial_loaded = true
    end
end

T.test_scrolling_works = function ()
    ensure_initial_page()

    -- Fetch height of document body
    w.view:eval_js("document.body.getClientRects()[0].height", { callback = test.continue })
    local doc_height = test.wait()

    local get_scroll_y = function ()
        w.view:eval_js("window.scrollY", { callback = test.continue })
        return test.wait()
    end

    assert.is_equal(0, get_scroll_y(),
        "Scroll position should start at top.")

    w:scroll{ yrel = 100 }
    test.wait_until(function () return w.view.scroll.y == 100 end)
    assert.is_equal(100, get_scroll_y(),
        "Relative scrolling failed")

    w:scroll{ yrel = -100 }
    test.wait_until(function () return w.view.scroll.y == 0 end)
    assert.is_equal(0, get_scroll_y(),
        "Relative scrolling failed")

    w:scroll{ yrel = -100 }
    test.wait_for_idle()
    assert.is_equal(0, get_scroll_y(),
        "Scrolling didn't stop when already at end")

    w:scroll{ yrel = 100 }
    test.wait_until(function () return w.view.scroll.y == 100 end)
    assert.is_equal(100, get_scroll_y(),
        "Relative scrolling after scrolling against scroll-end failed")


    w:scroll{ y = 0 }
    assert.is_equal(0, get_scroll_y(),
        "Scrolling to top failed")

    w:scroll{ y = -1 }
    -- Scrolling to bottom requires a JS roundtrip to get document height
    -- first, so wait until that's finished before continuing...
    test.wait_until(function () return w.view.scroll.y > 0 end)
    assert.is_equal(doc_height - w.view.height, get_scroll_y(),
        "Scrolling to bottom failed")

    w:scroll{ ypct = 0 }
    test.wait_until(function () return w.view.scroll.y == 0 end)

    w:scroll{ ypct = 100 }
    test.wait_until(function () return w.view.scroll.y > 0 end)
    assert.is_equal(doc_height - w.view.height, get_scroll_y(),
        "Scrolling to 100% failed")
end

T.test_history_scroll_restoration = function ()
    ensure_initial_page()
    w:scroll{ y = 0 }
    test.wait_until(function () return w.view.scroll.y == 0 end)

    -- Scroll Page 1 to 200
    w:scroll{ y = 200 }
    test.wait_until(function () return w.view.scroll.y >= 200 end)
    local target_y = w.view.scroll.y

    -- Navigate to Page 2
    local page2_uri = test.http_server() .. "scroll.html?page2"
    w.view.uri = page2_uri
    test.wait_for_view(w.view)

    -- Navigate back to Page 1 without user scrolling
    test.wait_until(function () return w.view:can_go_back() end)
    w:back(1)
    test.wait_for_view(w.view)

    test.wait_until(function () return w.view.scroll.y == target_y end)
    assert.is_equal(target_y, w.view.scroll.y, "History scroll position should be restored when user did not scroll")

    -- Clean up: reset scroll position to 0
    w:scroll{ y = 0 }
    test.wait_until(function () return w.view.scroll.y == 0 end)
end

T.test_scroll_relative_and_half_page = function ()
    ensure_initial_page()
    w:scroll{ y = 0 }
    test.wait_until(function () return w.view.scroll.y == 0 end)

    -- Test relative scrolling via scroll_by
    w:scroll{ yrel = 120 }
    test.wait_until(function () return w.view.scroll.y >= 120 end)

    local prev_y = w.view.scroll.y

    -- Test half page relative scrolling
    w:scroll{ ypagerel = 0.5 }
    test.wait_until(function () return w.view.scroll.y > prev_y end)

    -- Test relative scroll up
    local high_y = w.view.scroll.y
    w:scroll{ yrel = -100 }
    test.wait_until(function () return w.view.scroll.y < high_y end)

    -- Reset to 0
    w:scroll{ y = 0 }
    test.wait_until(function () return w.view.scroll.y == 0 end)
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
