--- Select a page element with a visual interface.
--
-- This web module allows other Lua modules to select page elements with the
-- same interface as that used by the follow mode plugin: a visual overlay is
-- shown that allows the users to type to filter visible hints. For example,
-- this module is used by the `formfiller` module when selecting a form to add.
--
-- @module select_wm
-- @copyright 2017 Aidan Holm <aidanholm@gmail.com>

local ceil, floor, max = math.ceil, math.floor, math.max

local _M = {}

local ui = ipc_channel("select_wm")

-- Label making

-- Calculates the minimum number of characters needed in a hint given a
-- charset of a certain length (I.e. the base)
local function max_hint_len(size, base)
    local len = 0
    if base == 1 then return size end
    while size > 0 do size, len = floor(size / base), len + 1 end
    return len
end

-- Reverse a UTF8 string: multibyte sequences are reversed twice
local function utf8_rev (s)
    s = s:gsub(utf8.charpattern, function (ch) return #ch > 1 and ch:reverse() end)
    return s:reverse()
end

local function charset(seq, size)
    if size <= 0 then return {} end
    local base, digits, labels = utf8.len(seq), {}, {}
    for ch in seq:gmatch(utf8.charpattern) do digits[#digits+1] = ch end

    local maxlen = max_hint_len(size, base)

    for n = 1, size do
        local t, i, j, d = {}, 1, n
        repeat
            d, n = (n % base) + 1, floor(n / base)
            rawset(t, i, rawget(digits, d))
            i = i + 1
        until n == 0

        rawset(labels, j, string.rep(digits[1], maxlen-i+1) .. utf8_rev(table.concat(t, "")))
    end
    return labels
end

-- Different hint label styles
local label_styles = {
    charset = function (seq)
        assert(type(seq) == "string" and #seq > 0, "invalid sequence")
        return function (size) return charset(seq, size) end
    end,

    numbers = function ()
        return function (size) return charset("0123456789", size) end
    end,

    -- Interleave style
    interleave = function (left, right)
        assert(type(left) == "string" and type(right) == "string",
               "left and right parameters must be strings")
        assert(#left > 1 or #right > 1,
               "either left or right parameters' length must be greater than 1")
        local cmap = {}
        for ch in (left..right):gmatch(utf8.charpattern) do
            if cmap[ch] then
                error("duplicate characters %s in hint strings %s, %s", ch, left, right)
            else
                cmap[ch] = 1
            end
        end
        return function (size)
            if size <= 0 then return {} end
            local function allstrings(n, t, k, s)
                k, s = k or 1, s or {}
                if k > n then
                    coroutine.yield(table.concat(s))
                else
                    for i = 1, #t do
                        s[k] = t[i]
                        allstrings(n, t, k+1, s)
                    end
                end
            end
            local function permute(n, t)
                return coroutine.wrap(allstrings), n, t
            end

            -- calculate the hinting length
            local hint_len = 1
            while true do
                local lo, hi = floor(hint_len/2), ceil(hint_len/2)
                if (#left)^lo * (#right)^hi + (#left)^hi * (#right)^lo >= size then break end
                hint_len = hint_len + 1
            end

            local tleft, tright = {}, {}
            left:gsub(utf8.charpattern, function(c) table.insert(tleft, c) end)
            right:gsub(utf8.charpattern, function(c) table.insert(tright, c) end)
            local labels = {}
            local lo, hi = floor(hint_len/2), ceil(hint_len/2)
            for a in permute(hi, tleft) do
                for b in permute(lo, tright) do
                    rawset(labels, size, a:gsub('()('..utf8.charpattern..')',
                                                function(p, c) return c..b:sub(p, p+#c-1) end))
                    size = size - 1
                    if size == 0 then return labels end
                end
            end
            for a in permute(hi, tright) do
                for b in permute(lo, tleft) do
                    rawset(labels, size, a:gsub('()('..utf8.charpattern..')',
                                                function(p, c) return c..b:sub(p, p+#c-1) end))
                    size = size - 1
                    if size == 0 then return labels end
                end
            end
            return labels
        end
    end,

    -- Chainable style: sorts labels
    sort = function (make_labels)
        return function (size)
            local labels = make_labels(size)
            table.sort(labels)
            return labels
        end
    end,

    -- Chainable style: reverses label strings
    reverse = function (make_labels)
        return function (size)
            local labels = make_labels(size)
            for i = 1, #labels do
                rawset(labels, i, utf8_rev(rawget(labels, i)))
            end
            return labels
        end
    end,

    trim = function (make_labels)
        return function (size)
            local labels = make_labels(size)
            local P, prefixes = {}, {}
            for i, l in ipairs(labels) do
                local p = l:gsub(utf8.charpattern.."$", "")
                prefixes[i] = p
                local cur = l
                while #cur > 0 do
                    P[cur] = (P[cur] or 0) + 1
                    cur = cur:gsub(utf8.charpattern.."$", "")
                end
            end
            for i, p in ipairs(prefixes) do
                if #p > 0 and P[p] == 1 then
                    labels[i] = p
                end
            end
            return labels
        end
    end,
}

-- Default label style
local label_maker
do
    local s = label_styles
    label_maker = s.trim(s.sort(s.interleave("12345", "67890")))
end

local function bounding_boxes_intersect(a, b)
    if a.x + a.w < b.x then return false end
    if b.x + b.w < a.x then return false end
    if a.y + a.h < b.y then return false end
    if b.y + b.h < a.y then return false end
    return true
end

local CLIENT_RECTS_JS = [=[
    var rects = element.getClientRects();
    if (rects.length == 0)
        return undefined;
    var rect = {
        "top": rects[0].top,
        "bottom": rects[0].bottom,
        "left": rects[0].left,
        "right": rects[0].right,
    };
    for (var i = 1; i < rects.length; i++) {
        rect.top = Math.min(rect.top, rects[i].top);
        rect.bottom = Math.max(rect.bottom, rects[i].bottom);
        rect.left = Math.min(rect.left, rects[i].left);
        rect.right = Math.max(rect.right, rects[i].right);
    }
    rect.width = rect.right - rect.left;
    rect.height = rect.bottom - rect.top;
    return rect;
]=]

local SCAN_FRAME_JS = [=[
    var vw = window.innerWidth || 0;
    var vh = window.innerHeight || 0;
    if (vw <= 0 || vh <= 0)
        return [];
    try {
        if (window.frameElement) {
            var fr = window.frameElement.getBoundingClientRect();
            var pw = window.parent.innerWidth || 0;
            var ph = window.parent.innerHeight || 0;
            if (fr.width <= 0 || fr.height <= 0 ||
                fr.right < 0 || fr.left > pw ||
                fr.bottom < 0 || fr.top > ph) {
                return [];
            }
        }
    } catch (e) {}

    var nodes;
    if (typeof selector === "string") {
        if (!document.body)
            return [];
        nodes = document.body.querySelectorAll(selector);
    } else if (elemList) {
        nodes = elemList;
    } else {
        return [];
    }

    var sx = window.scrollX || 0;
    var sy = window.scrollY || 0;

    function getVisibleBB(el) {
        var rects = el.getClientRects();
        var n = rects ? rects.length : 0;
        if (n === 0)
            return null;

        var left, top, width, height;
        if (!el.firstElementChild) {
            var found = false;
            for (var i = 0; i < n; i++) {
                var ri = rects[i];
                if (ri.width !== 0 && ri.height !== 0) {
                    left = ri.left;
                    top = ri.top;
                    width = ri.width;
                    height = ri.height;
                    found = true;
                    break;
                }
            }
            if (!found)
                return null;
        } else {
            var r0 = rects[0];
            var minT = r0.top, maxB = r0.bottom, minL = r0.left, maxR = r0.right;
            for (var j = 1; j < n; j++) {
                var rj = rects[j];
                if (rj.top < minT) minT = rj.top;
                if (rj.bottom > maxB) maxB = rj.bottom;
                if (rj.left < minL) minL = rj.left;
                if (rj.right > maxR) maxR = rj.right;
            }
            left = minL;
            top = minT;
            width = maxR - minL;
            height = maxB - minT;
        }

        if (width === 0 || height === 0)
            return null;

        if (vw < left || left + width < 0 || vh < top || top + height < 0)
            return null;

        var cs = window.getComputedStyle(el);
        var display = cs.display;
        if (display === "none" || cs.visibility === "hidden")
            return null;

        if (display === "inline") {
            var parent = el.parentElement;
            if (parent) {
                var pd = window.getComputedStyle(parent).display;
                if (pd === "block" || pd === "inline-block") {
                    var pr = parent.getBoundingClientRect();
                    var maxW = parent.offsetWidth - (left - pr.left);
                    if (width > maxW)
                        width = maxW;
                    if (width <= 0 || left + width < 0)
                        return null;
                }
            }
        }

        if (el.tagName === "A") {
            var first = el.firstElementChild;
            if (first && first.tagName === "IMG" && !first.nextElementSibling) {
                var imgBB = getVisibleBB(first);
                if (imgBB)
                    return imgBB;
            }
        }

        return {
            x: sx + left,
            y: sy + top,
            w: width,
            h: height
        };
    }

    var results = [];
    var len = (nodes && nodes.length) || 0;
    for (var k = 0; k < len; k++) {
        var el = nodes[k];
        if (!el)
            continue;
        var bb = getVisibleBB(el);
        if (!bb)
            continue;

        var text = "";
        var tag = el.tagName || "";
        var etype = (el.type !== undefined && el.type !== null) ? el.type : el.getAttribute("type");
        if (etype !== "password") {
            if (tag !== "BODY")
                text = el.textContent || "";
            if (text === "" && typeof el.value === "string")
                text = el.value;
        }
        if (text === "")
            text = el.getAttribute("placeholder") || "";

        results.push({
            elem: el,
            bb: bb,
            text: text,
            tag_name: tag
        });
    }
    return results;
]=]

local BUILD_OVERLAY_JS = [=[
    var root = (document.body && document.body.parentElement) || document.documentElement;
    if (!root)
        return null;
    var sx = window.scrollX || 0;
    var sy = window.scrollY || 0;
    var overlay = document.createElement("div");
    overlay.setAttribute("id", "luakit_select_overlay");
    var styleEl = document.createElement("style");
    styleEl.setAttribute("id", "luakit_select_stylesheet");
    styleEl.textContent = stylesheet;

    var overlays = [];
    var labels = [];
    var n = (specs && specs.length) || 0;
    for (var i = 0; i < n; i++) {
        var s = specs[i];
        var rx = Math.trunc(s.x);
        var ry = Math.trunc(s.y);
        var rw = Math.trunc(s.w);
        var rh = Math.trunc(s.h);
        var lx = Math.trunc(Math.max(s.x - 10, sx));
        var ly = Math.trunc(Math.max(s.y - 10, sy));

        var ov = document.createElement("span");
        ov.setAttribute("class", "hint_overlay hint_overlay_" + s.tag);
        ov.setAttribute("style", "left: " + rx + "px; top: " + ry + "px; width: " + rw + "px; height: " + rh + "px;");
        overlay.appendChild(ov);
        overlays.push(ov);

        var lb = document.createElement("span");
        lb.setAttribute("class", "hint_label hint_label_" + s.tag);
        lb.setAttribute("style", "left: " + lx + "px; top: " + ly + "px;");
        lb.textContent = s.label;
        overlay.appendChild(lb);
        labels.push(lb);
    }

    root.appendChild(overlay);
    root.appendChild(styleEl);
    return {
        overlay: overlay,
        stylesheet: styleEl,
        overlays: overlays,
        labels: labels
    };
]=]

local function get_element_bb_if_visible(element, wbb, client_rects)
    -- Find the element bounding box
    local r

    if not element.first_child then
        r = element:client_rects()
        for i=#r,1,-1 do
            if r[i].width == 0 or r[i].height == 0 then table.remove(r, i) end
        end
        if #r == 0 then
            return nil
        end
        r = r[1]
    elseif client_rects then
        r = client_rects(element)
    else
        r = element.rect
    end

    if not r then
        return nil
    end

    local rbb = {
        x = wbb.x + r.left,
        y = wbb.y + r.top,
        w = r.width,
        h = r.height,
    }

    if rbb.w == 0 or rbb.h == 0 or not bounding_boxes_intersect(wbb, rbb) then
        return nil
    end

    local style = element.style
    local display = style.display
    if display == "none" or style.visibility == "hidden" then
        return nil
    end

    -- Clip bounding box!
    if display == "inline" then
        local parent = element.parent
        if parent then
            local pd = parent.style.display
            if pd == "block" or pd == "inline-block" then
                local w = parent.rect.width
                w = w - ((wbb.x + r.left) - parent.rect.left)
                if rbb.w > w then rbb.w = w end
                if rbb.w <= 0 or not bounding_boxes_intersect(wbb, rbb) then
                    return nil
                end
            end
        end
    end

    -- If a link element contains one image, use the image dimensions
    if element.tag_name == "A" then
        local first = element.first_child
        if first and first.tag_name == "IMG" and not first.next_sibling then
            return get_element_bb_if_visible(first, wbb, client_rects) or rbb
        end
    end

    return rbb
end

local function frame_find_hints(frame, elements)
    local selector = nil
    local elem_list = nil

    if type(elements) == "string" then
        selector = elements
    else
        elem_list = {}
        for _, e in ipairs(elements) do
            if e.owner_document == frame.doc then
                elem_list[#elem_list + 1] = e
            end
        end
        if #elem_list == 0 then
            return {}
        end
    end

    local scan_fn, scan_err = frame.doc:wrap_js(SCAN_FRAME_JS, {"selector", "elemList"})
    if scan_fn then
        local res, call_err = scan_fn(selector, elem_list)
        if type(res) == "table" then
            msg.debug("frame_find_hints: %d visible hints found", #res)
            return res
        end
        if call_err then
            msg.warn("frame_find_hints JS execution failed: %s", call_err)
        end
    elseif scan_err then
        msg.warn("frame_find_hints wrap_js failed: %s", scan_err)
    end

    -- Fallback path
    local hints = {}
    local list = elem_list or frame.body:query(selector)
    local client_rects = frame.doc:wrap_js(CLIENT_RECTS_JS, {"element"})

    local w = frame.doc.window
    local wbb = {
        x = w.scroll_x,
        y = w.scroll_y,
        w = w.inner_width,
        h = w.inner_height,
    }

    for _, element in ipairs(list) do
        local rbb = get_element_bb_if_visible(element, wbb, client_rects)
        if rbb then
            local text = ""
            local tag = element.tag_name
            if element.type ~= "password" then
                if tag ~= "BODY" then
                    text = element.text_content
                end
                if text == "" then text = element.value or "" end
            end
            if text == "" then text = element.attr.placeholder or "" end
            hints[#hints + 1] = { elem = element, bb = rbb, text = text, tag_name = tag }
        end
    end
    msg.debug("frame_find_hints (fallback): %d/%d elements are visible", #hints, #list)

    return hints
end

local function sort_hints_top_left(a, b)
    local dtop = a.bb.y - b.bb.y
    if dtop ~= 0 then
        return dtop < 0
    else
        return a.bb.x - b.bb.x < 0
    end
end

--- Make hint labels.
-- @tparam number num Number of labels
-- @treturn table Array of label strings
function _M.make_labels(num)
    if num <= 0 then return {} end
    return label_maker(num)
end

local function find_frames(root_frame) -- luacheck: ignore 211
    if not root_frame.body then
        return {}
    end

    local subframes = {}
    for _, frame in ipairs(root_frame.body:query("frame, iframe")) do
        if frame.document then
            table.insert(subframes, frame)
        end
    end
    local frames = { root_frame }

    -- For each frame/iframe element, recurse
    for _, frame in ipairs(subframes) do
        local f = { doc = frame.document, body = frame.document.body }
        local s = find_frames(f)
        for _, sf in ipairs(s) do
            frames[#frames + 1] = sf
        end
    end

    return frames
end

local page_states = {}

local function init_frame(frame, stylesheet)
    assert(frame.doc)
    assert(frame.body)

    frame.overlay = frame.doc:create_element("div", { id = "luakit_select_overlay" })
    frame.stylesheet = frame.doc:create_element("style", { id = "luakit_select_stylesheet" }, stylesheet)

    frame.body.parent:append(frame.overlay)
    frame.body.parent:append(frame.stylesheet)
end

local function cleanup_frame(frame)
    if frame.on_doc_destroy and frame.doc then
        frame.doc:remove_signal("destroy", frame.on_doc_destroy)
        frame.on_doc_destroy = nil
    end
    if frame.overlay then
        frame.overlay:remove()
        frame.overlay = nil
    end
    if frame.stylesheet then
        frame.stylesheet:remove()
        frame.stylesheet = nil
    end
end

local function hint_matches(hint, hint_pat, text_pat)
    if hint_pat ~= nil and string.find(hint.label, hint_pat) then return true end
    if text_pat ~= nil and string.find(hint.text, text_pat) then return true end
    return false
end

local function filter(state, hint_pat, text_pat)
    state.num_visible_hints = 0
    for _, hint in pairs(state.hints) do
        local old_hidden = hint.hidden
        hint.hidden = not hint_matches(hint, hint_pat, text_pat)

        if not hint.hidden then
            state.num_visible_hints = state.num_visible_hints + 1
        end

        if not old_hidden and hint.hidden then
            -- Save old style, set new style to "display: none"
            hint.overlay_style = hint.overlay_elem.attr.style
            hint.label_style = hint.label_elem.attr.style
            hint.overlay_elem.attr.style = "display: none;"
            hint.label_elem.attr.style = "display: none;"
        elseif old_hidden and not hint.hidden then
            -- Restore saved style
            hint.overlay_elem.attr.style = hint.overlay_style
            hint.label_elem.attr.style = hint.label_style
        end
    end
end

local function focus(state, step)
    local last = state.focused
    local index

    local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end

    if state.num_visible_hints == 0 then return end

    -- Advance index to the first non-hidden item
    if step == 0 then
        index = last and last or 1
        while state.hints[index].hidden do
            index = index + 1
            if index > #state.hints then index = 1 end
        end
        if index == last then return end
    end

    -- Which hint to focus?
    if step ~= 0 and last then
        index = last
        while step ~= 0 do
            repeat
                index = index + sign(step)
                if index < 1 then index = #state.hints end
                if index > #state.hints then index = 1 end
            until not state.hints[index].hidden
            step = step - sign(step)
        end
    end

    local new_hint = state.hints[index]

    -- Save and update class for the new hint
    new_hint.orig_class = new_hint.overlay_elem.attr.class
    new_hint.overlay_elem.attr.class = new_hint.orig_class .. " hint_selected"

    -- Restore the original class for the old hint
    if last then
        local old_hint = state.hints[last]
        old_hint.overlay_elem.attr.class = old_hint.orig_class
        old_hint.orig_class = nil
    end

    state.focused = index

    return new_hint
end

--- Scan a web page for visible matching elements and prepare selection state.
--
-- @tparam page page The web page in which to scan for elements.
-- @tparam string|{dom_element} elements A selector to filter elements, or an array of elements.
-- @tparam boolean ignore_case `true` if text case should be ignored.
-- @treturn number The number of visible hints found.
function _M.scan(page, elements, ignore_case)
    assert(type(page) == "page")
    assert(type(elements) == "string" or type(elements) == "table")
    local page_id = page.id
    if page_states[page_id] then
        _M.leave(page)
    end

    local root = page.document
    local state = { page = page }
    page_states[page_id] = state

    local frames = {}
    if root and root.body then
        table.insert(frames, { doc = root, body = root.body })
    end
    local docs = page:get_frames() or {}
    for _, doc in ipairs(docs) do
        if doc and doc.body and doc ~= root then
            table.insert(frames, { doc = doc, body = doc.body })
        end
    end
    state.frames = frames
    state.focused = nil
    state.hints = {}
    state.ignore_case = ignore_case or false

    -- Find all hints in the viewport
    for _, frame in ipairs(state.frames) do
        frame.hints = frame_find_hints(frame, elements)
        -- Build an array of all hints
        for _, hint in ipairs(frame.hints) do
            state.hints[#state.hints+1] = hint
        end
    end

    table.sort(state.hints, sort_hints_top_left)
    return #state.hints
end

--- Display hint elements on the target page.
-- @tparam page page Target web page
-- @tparam table labels Hint label strings
-- @tparam string stylesheet CSS stylesheet string
_M.show_hints = function (page, labels, stylesheet)
    assert(type(page) == "page")
    assert(type(labels) == "table")
    assert(type(stylesheet) == "string")
    local page_id = page.id
    local state = page_states[page_id]
    assert(state ~= nil)

    assert(#state.hints == #labels)

    for i, hint in ipairs(state.hints) do
        hint.label = labels[i]
        hint.hidden = false
    end

    for _, frame in ipairs(state.frames) do
        local specs = {}
        for i, hint in ipairs(frame.hints) do
            local r = hint.bb
            specs[i] = {
                x = r.x,
                y = r.y,
                w = r.w,
                h = r.h,
                tag = hint.tag_name or hint.elem.tag_name,
                label = hint.label,
            }
        end

        local built = false
        local build_fn, build_err = frame.doc:wrap_js(BUILD_OVERLAY_JS, {"specs", "stylesheet"})
        if build_fn then
            local res, call_err = build_fn(specs, stylesheet)
            if type(res) == "table" and res.overlay and res.stylesheet then
                frame.overlay = res.overlay
                frame.stylesheet = res.stylesheet
                local overlays = res.overlays or {}
                local label_elems = res.labels or {}
                for i, hint in ipairs(frame.hints) do
                    hint.overlay_elem = overlays[i]
                    hint.label_elem = label_elems[i]
                end
                built = true
            elseif call_err then
                msg.warn("show_hints JS execution failed: %s", call_err)
            end
        elseif build_err then
            msg.warn("show_hints wrap_js failed: %s", build_err)
        end

        if not built then
            local fwr = frame.doc.window
            local fsx, fsy = fwr.scroll_x, fwr.scroll_y
            init_frame(frame, stylesheet)
            for _, hint in ipairs(frame.hints) do
                local tag = hint.tag_name or hint.elem.tag_name
                local r = hint.bb

                local overlay_style = string.format("left: %dpx; top: %dpx; width: %dpx; height: %dpx;",
                    r.x, r.y, r.w, r.h)
                local label_style = string.format("left: %dpx; top: %dpx;", max(r.x-10, fsx), max(r.y-10, fsy))

                local overlay_class = "hint_overlay hint_overlay_" .. tag
                local label_class = "hint_label hint_label_" .. tag
                hint.overlay_elem = frame.doc:create_element("span", {
                    class = overlay_class,
                    style = overlay_style,
                })
                hint.label_elem = frame.doc:create_element("span", {
                    class = label_class,
                    style = label_style,
                }, hint.label)

                frame.overlay:append(hint.overlay_elem)
                frame.overlay:append(hint.label_elem)
            end
        end
    end

    for _, frame in ipairs(state.frames) do
        frame.on_doc_destroy = function ()
            cleanup_frame(frame)
        end
        frame.doc:add_signal("destroy", frame.on_doc_destroy)
    end
    state.on_page_destroy = function ()
        _M.leave(page_id)
    end
    page:add_signal("destroy", state.on_page_destroy)

    state.num_visible_hints = #state.hints
    return focus(state, 0), state.num_visible_hints
end

--- Enter selection/hint mode on a page.
-- @tparam page page Target page
-- @tparam table|string elements Elements query string or table
-- @tparam string stylesheet CSS stylesheet string
-- @tparam boolean ignore_case Ignore case when filtering
_M.enter = function (page, elements, stylesheet, ignore_case)
    assert(type(page) == "page")
    assert(type(elements) == "string" or type(elements) == "table")
    assert(type(stylesheet) == "string")

    local count = _M.scan(page, elements, ignore_case)
    local labels = _M.make_labels(count)
    return _M.show_hints(page, labels, stylesheet)
end

--- Leave element selection mode on a web page.
--
-- The web page must be in element selection mode.
--
-- @tparam page|number page The web page (or the web page id) in which to
-- leave element selection.
function _M.leave(page)
    if type(page) == "page" then page = page.id end
    assert(type(page) == "number")

    local state = page_states[page]
    if not state then return end
    if state.on_page_destroy and state.page then
        state.page:remove_signal("destroy", state.on_page_destroy)
        state.on_page_destroy = nil
    end
    for _, frame in ipairs(state.frames) do
        cleanup_frame(frame)
    end
    page_states[page] = nil
end

--- Update the element selection interface when user selection text changes.
--
-- The web page must be in element selection mode.
--
-- @tparam page page The web page.
-- @tparam string hint_pat The hint pattern filter.
-- @tparam string text_pat The text pattern filter.
-- @tparam string text The full text.
-- @treturn table The currently focused hint.
-- @treturn number The number of currently visible hints.
function _M.changed(page, hint_pat, text_pat, text)
    assert(type(page) == "page")
    assert(hint_pat == nil or type(hint_pat) == "string")
    assert(text_pat == nil or type(text_pat) == "string")
    assert(type(text) == "string")

    local state = page_states[page.id]
    if not state then return nil, 0 end

    if state.ignore_case then
        local convert = function(pat)
            if pat == nil then return nil end
            local converter = function (ch) return '[' .. string.upper(ch) .. string.lower(ch) .. ']' end
            return string.gsub(pat, '(%a)', converter)
        end
        hint_pat = convert(hint_pat)
        text_pat = convert(text_pat)
    end

    filter(state, hint_pat, text_pat)
    return focus(state, 0), state.num_visible_hints
end

--- Update the element selection interface when the user moves the focus.
--
-- The web page must be in element selection mode.
--
-- @usage
--
--     function handle_next (page)
--         select_wm.focus(page, 1)
--     end
--     function handle_prev (page)
--         select_wm.focus(page, -1)
--     end
--
-- @tparam page page The web page.
-- @tparam number step Relative number of tags to shift focus by.
-- @treturn table The currently focused hint.
-- @treturn number The number of currently visible hints.
function _M.focus(page, step)
    assert(type(page) == "page")
    assert(type(step) == "number")
    local state = page_states[page.id]
    if not state then return nil, 0 end
    return focus(state, step), state.num_visible_hints
end

--- Get the current state of element hints on a web page.
--
-- The web page must be in element selection mode.
--
-- @tparam page page The web page.
-- @treturn table The current hint state for `page`.
function _M.hints(page)
    assert(type(page) == "page")
    local state = page_states[page.id]
    if not state then return {} end
    return state.hints
end

--- Get the currently focused element hint on a web page.
--
-- The web page must be in element selection mode.
--
-- @tparam page page The web page.
-- @treturn table The currently focused hint.
function _M.focused_hint(page)
    assert(type(page) == "page")
    local state = page_states[page.id]
    if not state or not state.focused then return nil end
    return state.hints[state.focused]
end

ui:add_signal("set_label_maker", function (_, _, f)
    setfenv(f, label_styles)
    label_maker = f(label_styles)
end)

return _M

-- vim: et:sw=4:ts=8:sts=4:tw=80
