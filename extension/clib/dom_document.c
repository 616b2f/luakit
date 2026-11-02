/*
 * Copyright © 2016 Aidan Holm <aidanholm@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include "extension/extension.h"
#include "extension/clib/dom_document.h"
#include "extension/clib/dom_element.h"
#include "common/tokenize.h"
#include "common/luauniq.h"
#include "common/luah.h"
#include "common/luajs.h"
#include "common/log.h"

#include <stdlib.h>

#define REG_KEY "luakit.uniq.registry.dom_document"

static lua_class_t dom_document_class;

LUA_OBJECT_FUNCS(dom_document_class, dom_document_t, dom_document);

static guint64
js_value_get_unique_id(JSCValue *val)
{
    JSCContext *ctx = jsc_value_get_context(val);
    JSCValue *js_id = jsc_value_object_get_property(val, "__luakit_id");
    guint64 id;
    if (jsc_value_is_undefined(js_id)) {
        static guint64 next_id = 1;
        id = next_id++;
        JSCValue *new_id = jsc_value_new_number(ctx, id);
        jsc_value_object_set_property(val, "__luakit_id", new_id);
        g_object_unref(new_id);
    } else {
        id = (guint64)jsc_value_to_double(js_id);
    }
    g_object_unref(js_id);
    return id;
}

static dom_document_t*
luaH_check_dom_document(lua_State *L, gint udx)
{
    dom_document_t *document = luaH_checkudata(L, udx, &dom_document_class);
    if (!document->document)
        luaL_argerror(L, udx, "DOM document no longer valid");
    return document;
}

gint
luaH_dom_document_from_webkit_dom_document(lua_State *L, JSCValue *doc)
{
    if (!doc || jsc_value_is_null(doc) || jsc_value_is_undefined(doc)) {
        lua_pushnil(L);
        return 1;
    }

    guint64 id = js_value_get_unique_id(doc);
    void *ptr = (void*)(uintptr_t)id;

    if (luaH_uniq_get_ptr(L, REG_KEY, ptr))
        return 1;

    dom_document_t *document = dom_document_new(L);
    document->document = g_object_ref(doc);
    document->uniq_id = id;

    luaH_uniq_add_ptr(L, REG_KEY, ptr, -1);
    return 1;
}

dom_document_t *
luaH_to_dom_document(lua_State *L, gint idx)
{
    return luaH_toudata(L, idx, &dom_document_class);
}

static gint
luaH_dom_document_gc(lua_State *L)
{
    dom_document_t *document = luaH_toudata(L, 1, &dom_document_class);
    if (document && document->document) {
        if (document->uniq_id)
            luaH_uniq_del_ptr(L, REG_KEY, (void*)(uintptr_t)document->uniq_id);
        g_object_unref(document->document);
        document->document = NULL;
    }
    return luaH_object_gc(L);
}

static gint
luaH_dom_document_push_body(lua_State *L, dom_document_t *document)
{
    JSCValue *body = jsc_value_object_get_property(document->document, "body");
    gint ret = luaH_dom_element_from_node(L, body);
    g_object_unref(body);
    return ret;
}

static gint
luaH_dom_document_window_index(lua_State *L)
{
    dom_document_t *document = luaH_check_dom_document(L, lua_upvalueindex(1));
    const gchar *prop = luaL_checkstring(L, 2);
    luakit_token_t token = l_tokenize(prop);

    JSCContext *ctx = jsc_value_get_context(document->document);
    JSCValue *window = jsc_context_get_value(ctx, "window");

    const gchar *js_prop = NULL;
    switch (token) {
        case L_TK_SCROLL_X: js_prop = "scrollX"; break;
        case L_TK_SCROLL_Y: js_prop = "scrollY"; break;
        case L_TK_INNER_WIDTH: js_prop = "innerWidth"; break;
        case L_TK_INNER_HEIGHT: js_prop = "innerHeight"; break;
        default:
            g_object_unref(window);
            return 0;
    }

    JSCValue *prop_val = jsc_value_object_get_property(window, js_prop);
    double val_num = jsc_value_to_double(prop_val);
    g_object_unref(prop_val);
    g_object_unref(window);

    lua_pushnumber(L, val_num);
    return 1;
}

static gint
luaH_dom_document_push_window_table(lua_State *L)
{
    /* create attribute table */
    lua_newtable(L);
    /* setup metatable */
    lua_createtable(L, 0, 2);
    /* push __index metafunction */
    lua_pushliteral(L, "__index");
    lua_pushvalue(L, 1); /* copy element userdata */
    lua_pushcclosure(L, luaH_dom_document_window_index, 1);
    lua_rawset(L, -3);
    lua_setmetatable(L, -2);
    return 1;
}

static gint
luaH_dom_document_create_element(lua_State *L)
{
    dom_document_t *document = luaH_check_dom_document(L, 1);
    const char *tagname = luaL_checkstring(L, 2);

    JSCContext *ctx = jsc_value_get_context(document->document);
    JSCValue *elem = jsc_value_object_invoke_method(document->document, "createElement", G_TYPE_STRING, tagname, G_TYPE_NONE);

    /* Set all attributes */
    if (lua_istable(L, 3)) {
        lua_pushnil(L);
        while (lua_next(L, 3) != 0) {
            const char *name = luaL_checkstring(L, -2);
            const char *value = luaL_checkstring(L, -1);
            JSCValue *ret = jsc_value_object_invoke_method(elem, "setAttribute", G_TYPE_STRING, name, G_TYPE_STRING, value, G_TYPE_NONE);
            if (ret) g_object_unref(ret);
            lua_pop(L, 1);
        }
    }

    /* Set inner text */
    if (lua_isstring(L, 4)) {
        const char *inner_text = lua_tostring(L, 4);
        JSCValue *inner_val = jsc_value_new_string(ctx, inner_text);
        jsc_value_object_set_property(elem, "textContent", inner_val);
        g_object_unref(inner_val);
    }

    gint ret = luaH_dom_element_from_node(L, elem);
    g_object_unref(elem);
    return ret;
}

static gint
luaH_dom_document_element_from_point(lua_State *L)
{
    dom_document_t *document = luaH_check_dom_document(L, 1);
    glong x = luaL_checknumber(L, 2),
          y = luaL_checknumber(L, 3);

    JSCValue *elem = jsc_value_object_invoke_method(document->document, "elementFromPoint", G_TYPE_INT, x, G_TYPE_INT, y, G_TYPE_NONE);
    gint ret = luaH_dom_element_from_node(L, elem);
    g_object_unref(elem);
    return ret;
}

static JSCValue *
dom_luajs_tovalue(lua_State *L, int idx, JSCContext *ctx)
{
    dom_element_t *elem = luaH_to_dom_element(L, idx);
    if (elem)
        return elem->element ? g_object_ref(elem->element) : jsc_value_new_null(ctx);

    dom_document_t *doc = luaH_to_dom_document(L, idx);
    if (doc)
        return doc->document ? g_object_ref(doc->document) : jsc_value_new_null(ctx);

    if (lua_type(L, idx) == LUA_TTABLE) {
        size_t len = lua_objlen(L, idx);
        int top = lua_gettop(L);
        JSCValue *res, *val;

        if (idx < 0)
            idx += top + 1;

        if (len) {
            res = jsc_value_new_array(ctx, G_TYPE_NONE);
            for (size_t i = 1; i <= len; i++) {
                lua_rawgeti(L, idx, (int)i);
                val = dom_luajs_tovalue(L, -1, ctx);
                if (!val) {
                    lua_settop(L, top);
                    g_object_unref(res);
                    return NULL;
                }
                jsc_value_object_set_property_at_index(res, (guint)(i - 1), val);
                lua_pop(L, 1);
                g_object_unref(val);
            }
        } else {
            res = jsc_value_new_object(ctx, NULL, NULL);
            lua_pushnil(L);
            while (lua_next(L, idx)) {
                if (lua_type(L, -2) != LUA_TSTRING) {
                    lua_pop(L, 1);
                    continue;
                }
                val = dom_luajs_tovalue(L, -1, ctx);
                if (!val) {
                    lua_settop(L, top);
                    g_object_unref(res);
                    return NULL;
                }
                jsc_value_object_set_property(res, lua_tostring(L, -2), val);
                lua_pop(L, 1);
                g_object_unref(val);
            }
        }
        return res;
    }

    return luajs_tovalue(L, idx, ctx);
}

static gint
dom_luajs_pushvalue(lua_State *L, JSCValue *value)
{
    if (!value || jsc_value_is_undefined(value) || jsc_value_is_null(value)) {
        lua_pushnil(L);
        return 1;
    }
    if (jsc_value_is_boolean(value)) {
        lua_pushboolean(L, jsc_value_to_boolean(value));
        return 1;
    }
    if (jsc_value_is_number(value)) {
        lua_pushnumber(L, jsc_value_to_double(value));
        return 1;
    }
    if (jsc_value_is_string(value)) {
        gchar *str = jsc_value_to_string(value);
        lua_pushstring(L, str);
        g_free(str);
        return 1;
    }
    if (jsc_value_is_array(value)) {
        JSCValue *len_val = jsc_value_object_get_property(value, "length");
        gint len = jsc_value_to_int32(len_val);
        g_object_unref(len_val);
        gint top = lua_gettop(L);
        lua_createtable(L, len, 0);
        for (gint i = 0; i < len; i++) {
            JSCValue *item = jsc_value_object_get_property_at_index(value, (guint)i);
            if (!dom_luajs_pushvalue(L, item)) {
                g_object_unref(item);
                lua_settop(L, top);
                return 0;
            }
            g_object_unref(item);
            lua_rawseti(L, -2, i + 1);
        }
        return 1;
    }
    if (jsc_value_is_object(value)) {
        if (jsc_value_object_is_instance_of(value, "Element"))
            return luaH_dom_element_from_node(L, value);
        if (jsc_value_object_is_instance_of(value, "Document"))
            return luaH_dom_document_from_webkit_dom_document(L, value);

        char **keys = jsc_value_object_enumerate_properties(value);
        int top = lua_gettop(L);
        lua_newtable(L);
        for (int i = 0; keys && keys[i]; i++) {
            char *key = keys[i];
            char *eptr;
            long n;
            if (*key && (n = strtol(key, &eptr, 10), !*eptr))
                lua_pushinteger(L, ++n);
            else
                lua_pushstring(L, key);

            JSCValue *val = jsc_value_object_get_property(value, key);
            if (!dom_luajs_pushvalue(L, val)) {
                g_object_unref(val);
                lua_settop(L, top);
                g_strfreev(keys);
                return 0;
            }
            g_object_unref(val);
            lua_rawset(L, -3);
        }
        g_strfreev(keys);
        return 1;
    }
    return 0;
}

static gint
luaH_dom_document_js_func_gc(lua_State *L)
{
    JSCValue **ud = lua_touserdata(L, 1);
    if (ud && *ud) {
        g_object_unref(*ud);
        *ud = NULL;
    }
    return 0;
}

static gint
luaH_dom_document_js_func(lua_State *L)
{
    JSCValue **ud = luaL_checkudata(L, lua_upvalueindex(1), "luakit.dom_document.js_func");
    luaH_check_dom_document(L, lua_upvalueindex(2));
    if (!ud || !*ud)
        return luaL_error(L, "JavaScript function no longer valid");

    JSCValue *func = *ud;
    JSCContext *ctx = jsc_value_get_context(func);

    gint argc = lua_gettop(L);
    JSCValue **args = argc > 0 ? g_alloca(sizeof(*args) * (size_t)argc) : NULL;
    for (gint i = 0; i < argc; i++) {
        args[i] = dom_luajs_tovalue(L, i + 1, ctx);
        if (!args[i]) {
            for (gint j = 0; j < i; j++)
                g_object_unref(args[j]);
            return luaL_error(L, "failed to convert argument %d to JavaScript", i + 1);
        }
    }

    JSCValue *ret = jsc_value_function_callv(func, (guint)argc, args);
    for (gint i = 0; i < argc; i++)
        g_object_unref(args[i]);

    JSCException *exception = jsc_context_get_exception(ctx);
    if (exception) {
        if (ret) g_object_unref(ret);
        char *e = jsc_exception_to_string(exception);
        warn("JSC document js_func exception: %s", e);
        jsc_context_clear_exception(ctx);
        lua_pushnil(L);
        lua_pushstring(L, e);
        g_free(e);
        return 2;
    }

    gint nret = dom_luajs_pushvalue(L, ret);
    if (ret) g_object_unref(ret);
    if (!nret) {
        lua_pushnil(L);
        lua_pushstring(L, "unable to push the result onto the Lua stack");
        return 2;
    }
    return nret;
}

static gint
luaH_dom_document_eval_js(lua_State *L)
{
    dom_document_t *document = luaH_check_dom_document(L, 1);
    const gchar *script = luaL_checkstring(L, 2);
    const gchar *source = NULL;
    gchar *owned_source = NULL;

    gint top = lua_gettop(L);
    if (top >= 3 && !lua_isnil(L, 3)) {
        luaH_checktable(L, 3);
        if (luaH_rawfield(L, 3, "source"))
            source = luaL_checkstring(L, -1);
        lua_settop(L, top);
    }

    if (!source)
        source = owned_source = luaH_callerinfo(L);

    JSCContext *ctx = jsc_value_get_context(document->document);
    if (!ctx) {
        g_free(owned_source);
        lua_pushnil(L);
        lua_pushstring(L, "JavaScript context not available");
        return 2;
    }

    luajs_log_and_clear_exception(ctx, "dom_document eval_js pre-clear");
    JSCValue *res = jsc_context_evaluate_with_source_uri(ctx, script, -1, source, 1);
    JSCException *exception = jsc_context_get_exception(ctx);

    if (exception) {
        if (res) g_object_unref(res);
        char *e = jsc_exception_to_string(exception);
        warn("JSC document eval exception in %s: %s", source, e);
        g_free(owned_source);
        jsc_context_clear_exception(ctx);
        lua_pushnil(L);
        lua_pushstring(L, e);
        g_free(e);
        return 2;
    }
    g_free(owned_source);

    if (jsc_value_is_function(res)) {
        JSCValue **ud = lua_newuserdata(L, sizeof(JSCValue *));
        *ud = res;
        luaL_getmetatable(L, "luakit.dom_document.js_func");
        lua_setmetatable(L, -2);
        lua_pushvalue(L, 1);
        lua_pushcclosure(L, luaH_dom_document_js_func, 2);
        return 1;
    }

    int ret = dom_luajs_pushvalue(L, res);
    g_object_unref(res);
    if (!ret) {
        lua_pushnil(L);
        lua_pushstring(L, "unable to push the result onto the Lua stack");
        return 2;
    }
    return ret;
}

static gint
luaH_dom_document_wrap_js(lua_State *L)
{
    luaH_check_dom_document(L, 1);
    luaL_checkstring(L, 2);
    if (!lua_isnil(L, 3) && !lua_isnone(L, 3))
        luaH_checktable(L, 3);
    else {
        lua_settop(L, 2);
        lua_newtable(L);
    }
    lua_settop(L, 3);

    lua_pushstring(L, "(function(");
    size_t nparams = lua_objlen(L, 3);
    for (size_t i = 1; i <= nparams; i++) {
        lua_rawgeti(L, 3, (int)i);
        if (i < nparams)
            lua_pushstring(L, ",");
    }
    lua_pushstring(L, "){");
    lua_concat(L, lua_gettop(L) - 3);

    lua_insert(L, 2);
    lua_pop(L, 1);

    lua_pushstring(L, "})");
    lua_concat(L, 3);

    return luaH_dom_document_eval_js(L);
}

static gint
luaH_dom_document_index(lua_State *L)
{
    if (luaH_usemetatable(L, 1, 2))
        return 1;

    dom_document_t *document = luaH_check_dom_document(L, 1);
    const char *prop = luaL_checkstring(L, 2);
    luakit_token_t token = l_tokenize(prop);

    switch(token) {
        PF_CASE(CREATE_ELEMENT, luaH_dom_document_create_element);
        PF_CASE(ELEMENT_FROM_POINT, luaH_dom_document_element_from_point);
        PF_CASE(EVAL_JS, luaH_dom_document_eval_js);
        PF_CASE(WRAP_JS, luaH_dom_document_wrap_js);
        case L_TK_BODY: return luaH_dom_document_push_body(L, document);
        case L_TK_WINDOW: return luaH_dom_document_push_window_table(L);
        default:
            return 0;
    }
}

void
dom_document_class_setup(lua_State *L)
{
    static const struct luaL_Reg dom_document_methods[] =
    {
        LUA_CLASS_METHODS(dom_document)
        { NULL, NULL }
    };

    static const struct luaL_Reg dom_document_meta[] =
    {
        LUA_OBJECT_META(dom_document)
        { "__index", luaH_dom_document_index },
        { "__gc", luaH_dom_document_gc },
        { NULL, NULL }
    };

    luaH_class_setup(L, &dom_document_class, "dom_document",
            (lua_class_allocator_t) dom_document_new,
            NULL, NULL,
            dom_document_methods, dom_document_meta);

    luaL_newmetatable(L, "luakit.dom_document.js_func");
    lua_pushcfunction(L, luaH_dom_document_js_func_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaH_uniq_setup(L, REG_KEY, "");
}

// vim: ft=c:et:sw=4:ts=8:sts=4:tw=80
