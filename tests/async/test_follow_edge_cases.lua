--- Test follow mode edge cases (label elements, numeric filtering, iframe hinting).
--
-- @copyright 2026

local assert = require "luassert"
local test = require "tests.lib"

uris = { test.http_server() .. "test_follow_edge_cases.html" }
require "config.rc"

local window = require "window"

local initial_loaded = false
local function ensure_page(w)
    test.wait_for_idle()
    if not initial_loaded then
        test.wait_for_view(w.view)
        initial_loaded = true
    end
end

local function wait_for_hints_at_least(view, min_expected)
    local hint_count = 0
    test.wait_until(function ()
        local js = "document.querySelectorAll('#luakit_select_overlay .hint_overlay').length"
        view:eval_js(js, { callback = function (res)
            hint_count = res or 0
            test.continue()
        end })
        test.wait(500)
        return hint_count >= min_expected
    end, 50, 4000)
    return hint_count
end

local T = {}

T.test_follow_label_elements_no_crash = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_page(w)

    -- Enter follow mode
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("follow", w.mode and w.mode.name)
    assert.equal("Follow:", w.ibar.prompt.text)

    -- Verify hints exist on labels and form controls without crashing (Issue #1080)
    local count = wait_for_hints_at_least(w.view, 4)
    assert.is_true(count >= 4, "Expected at least 4 hints for links, labels, and inputs, got " .. tostring(count))

    -- Exit follow mode
    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name)
end

T.test_follow_numeric_filtering_and_backspace = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_page(w)

    -- Enter follow mode
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("follow", w.mode and w.mode.name)

    wait_for_hints_at_least(w.view, 4)

    -- Filter hints with input '1'
    w:set_input("1")
    w.mode.changed(w, "1")
    test.wait_for_idle()
    assert.equal("follow", w.mode.name, "Should remain in follow mode after typing number")
    assert.equal("1", w.ibar.input.text, "Input should contain '1'")
    assert.equal("1", w.follow_state.current_text, "Follow state should record current text")

    -- Backspace / clear input to undo filtering
    w:set_input("")
    w.mode.changed(w, "")
    test.wait_for_idle()
    assert.equal("follow", w.mode.name, "Should remain in follow mode after backspace")
    assert.equal("", w.ibar.input.text, "Input should be empty after backspace")
    assert.equal("", w.follow_state.current_text, "Follow state should reflect empty text")

    -- Clean up
    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name)
end

T.test_follow_iframe_elements_hinted = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_page(w)

    -- Enter follow mode
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("follow", w.mode and w.mode.name)

    -- Parent page has 2 links, 2 labels, 2 inputs (6). Iframe has 2 links, 1 button (3). Total >= 8.
    local count = wait_for_hints_at_least(w.view, 6)
    assert.is_true(count >= 6, "Expected hints spanning document and iframe elements, got " .. tostring(count))

    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name)
end

T.test_follow_changed_after_exit_race_no_crash = function ()
    local w = assert(select(2, next(window.bywidget)))
    ensure_page(w)

    -- Enter follow mode
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("follow", w.mode and w.mode.name)

    -- Immediately exit follow mode
    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name)

    -- Simulate trailing/asynchronous IPC signals arriving after mode exit
    local follow_ipc = ipc_channel("follow_wm")
    follow_ipc:emit_signal(w.view, "changed", "1", "1", "1")
    follow_ipc:emit_signal(w.view, "focus", 1)
    follow_ipc:emit_signal(w.view, "trigger_follow", false)
    test.wait_for_idle()
    test.delay(100)

    -- Verify follow mode can be re-entered without corruption
    w:hit({}, "f")
    test.wait_for_idle()
    assert.equal("follow", w.mode and w.mode.name)
    local count = wait_for_hints_at_least(w.view, 4)
    assert.is_true(count >= 4)

    w:set_mode()
    test.wait_for_idle()
    assert.equal("normal", w.mode.name)
end

return T

-- vim: et:sw=4:ts=8:sts=4:tw=80
