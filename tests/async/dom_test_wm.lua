local ui = ipc_channel("tests.async.dom_test_wm")

ui:add_signal("run_dom_tests", function (_, page)
    if not page then
        ui:emit_signal("dom_tests_result", { success = false, error = "missing page argument" })
        return
    end

    local doc = page.document
    if not doc then
        ui:emit_signal("dom_tests_result", { success = false, error = "missing document" })
        return
    end
    if not doc.body then
        ui:emit_signal("dom_tests_result", { success = false, error = "missing body" })
        return
    end

    local ok, err = pcall(function ()
        local container = doc:create_element("div")
        assert(container.tag_name == "DIV", "container tag_name should be DIV")

        container.inner_html = "<input id='inp' type='text' value='foo' />"
            .. "<input id='cb' type='checkbox' />"
            .. "<input id='rad' type='radio' />"
            .. "<input id='pwd' type='password' />"
            .. "<span id='s1'>First</span>"
            .. "<span id='s2'>Second</span>"
        doc.body:append(container)

        -- Test inner_html getter
        assert(container.inner_html:find("foo"), "container.inner_html should contain 'foo'")

        -- Test query
        local inputs = container:query("input")
        assert(#inputs == 4, "expected 4 inputs, got " .. tostring(#inputs))

        -- Test type getter
        assert(inputs[1].type == "text", "expected text, got " .. tostring(inputs[1].type))
        assert(inputs[2].type == "checkbox", "expected checkbox, got " .. tostring(inputs[2].type))
        assert(inputs[3].type == "radio", "expected radio, got " .. tostring(inputs[3].type))
        assert(inputs[4].type == "password", "expected password, got " .. tostring(inputs[4].type))

        -- Test value getter and setter
        assert(inputs[1].value == "foo", "expected value foo, got " .. tostring(inputs[1].value))
        inputs[1].value = "bar"
        assert(inputs[1].value == "bar", "expected updated value bar, got " .. tostring(inputs[1].value))

        -- Test checked getter and setter
        assert(inputs[2].checked == false, "expected initial checked to be false")
        inputs[2].checked = true
        assert(inputs[2].checked == true, "expected checked to be true after set")
        inputs[2].checked = false
        assert(inputs[2].checked == false, "expected checked to be false after unset")

        -- Test navigation: first_child, last_child, prev_sibling, next_sibling, parent
        local s1 = container:query("#s1")[1]
        local s2 = container:query("#s2")[1]
        assert(s1 and s2, "failed to query spans by id")

        assert(s2.prev_sibling and s2.prev_sibling.attr.id == "s1", "s2.prev_sibling failed")
        assert(s1.next_sibling and s1.next_sibling.attr.id == "s2", "s1.next_sibling failed")
        assert(container.last_child and container.last_child.attr.id == "s2", "container.last_child failed")
        assert(container.first_child and container.first_child.attr.id == "inp", "container.first_child failed")
        assert(s1.parent and s1.parent.tag_name == "DIV", "s1.parent failed")

        -- Test create_element with attributes and inner text (textContent)
        local b_style = "position:absolute;left:12px;top:34px;width:40px;height:20px;"
        local badge = doc:create_element("span", { id = "badge", style = b_style }, "42")
        container:append(badge)
        assert(badge.text_content == "42", "expected badge text_content '42', got " .. tostring(badge.text_content))
        assert(badge.rect.width >= 0 and badge.rect.height >= 0, "badge.rect width/height failed")
        assert(type(badge.rect.left) == "number" and type(badge.rect.top) == "number", "badge.rect left/top failed")

        -- Test doc:eval_js and doc:wrap_js with DOM element round-trip
        local sum = doc:eval_js("20 + 22")
        assert(sum == 42, "doc:eval_js expected 42, got " .. tostring(sum))
        local inspect_fn = assert(doc:wrap_js([=[
            return {
                first: elems[0],
                second_id: elems[1].id,
                count: elems.length
            };
        ]=], {"elems"}))
        local wrapped_res = inspect_fn({ s1, s2 })
        assert(type(wrapped_res) == "table", "doc:wrap_js result should be table")
        assert(wrapped_res.count == 2, "expected count 2, got " .. tostring(wrapped_res.count))
        assert(wrapped_res.second_id == "s2", "expected second_id 's2', got " .. tostring(wrapped_res.second_id))
        assert(wrapped_res.first == s1, "expected Element marshaled back to identical dom_element userdata")

        container:remove()
    end)

    if ok then
        ui:emit_signal("dom_tests_result", { success = true })
    else
        ui:emit_signal("dom_tests_result", { success = false, error = tostring(err) })
    end
end)

-- vim: et:sw=4:ts=8:sts=4:tw=80
