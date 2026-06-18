-- Integration-style test for the `edit` tool (lua/tai/tools.lua).
--
-- Focuses on the tricky matching behavior and the new `multi` parameter:
--   - When the first line of old_text appears multiple times in the file,
--     we must not stop at the first occurrence if the full block doesn't match
--     after it. We must continue and consider later possible alignments.
--   - `multi = true` must replace every matching occurrence of the block.
--
-- Run with:
--   nvim --headless -u NONE -c "luafile lua/tai/tests/edit_test.lua" -c "qa"
--
-- (Must run inside Neovim because edit() uses real vim buffers + nvim_buf_* APIs.)

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Minimal stubs so we can load the tools module without a full .tai config.
package.loaded["tai.config"] = {
    root = vim.fn.getcwd(),
    get_allowed_commands = function() return {} end,
}
package.loaded["tai.log"] = {
    debug = function() end,
    info  = function() end,
    error = function() end,
}

local tools = dofile("lua/tai/tools.lua")

local failures = 0

local function write_file(path, content)
    local f = io.open(path, "w")
    assert(f, "failed to open " .. path .. " for writing")
    f:write(content)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    assert(f, "failed to open " .. path .. " for reading")
    local content = f:read("*a")
    f:close()
    return content
end

local function assert_contains(haystack, needle, msg)
    if not haystack:find(needle, 1, true) then
        print("FAIL: " .. (msg or "expected to find " .. needle))
        failures = failures + 1
    end
end

local function assert_not_contains(haystack, needle, msg)
    if haystack:find(needle, 1, true) then
        print("FAIL: " .. (msg or "did not expect to find " .. needle))
        failures = failures + 1
    end
end

-- Helper for plain substring search (avoids any Lua string escape issues with special chars like '(' )
local function has_substr(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

local function assert_equals(actual, expected, msg)
    if actual ~= expected then
        print("FAIL: " .. (msg or ""))
        print("  expected: " .. tostring(expected))
        print("  actual:   " .. tostring(actual))
        failures = failures + 1
    end
end

print("=== edit tool tests ===\n")

----------------------------------------------------------------------
-- Test 1: basic single edit, no repeated lines
----------------------------------------------------------------------
do
    local path = "tai_edit_test_basic.txt"
    write_file(path, "line one\nline two\nline three\n")

    local result = tools.edit(path, "line two", "LINE TWO")
    assert_equals(result, "Patched " .. path, "basic edit should return Patched message")

    local content = read_file(path)
    assert_contains(content, "LINE TWO", "basic edit should have applied the change")
    assert_not_contains(content, "line two\n", "original line two should be gone")

    os.remove(path)
    print("PASS: basic single edit")
end

----------------------------------------------------------------------
-- Test 2: the important case - first line of old_text appears multiple times.
-- The full block only matches on the *second* occurrence.
-- Old naive streaming matcher could latch on the first "foo()" and then
-- fail when the continuation didn't match, or pick the wrong region.
----------------------------------------------------------------------
do
    local path = "tai_edit_test_repeated_first.txt"
    local original = table.concat({
        "function a()",
        "    process('start')",
        "    do_first_thing()",
        "end",
        "",
        "function b()",
        "    process('start')",
        "    do_second_thing()",
        "end",
    }, "\n") .. "\n"

    write_file(path, original)

    -- We deliberately target only the block under function b().
    -- The first line "    process('start')" also exists under function a().
    local old_block = "    process('start')\n    do_second_thing()"
    local new_block = "    process('start')\n    do_second_thing_v2()"

    local result = tools.edit(path, old_block, new_block)
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)

    -- The targeted block must have been updated.
    assert_contains(content, "do_second_thing_v2()", "should have updated the second occurrence")
    -- The earlier similar-looking block must be untouched.
    assert_contains(content, "do_first_thing()", "first similar block must remain unchanged")
    assert_not_contains(content, "do_second_thing()", "old second block should no longer exist")

    os.remove(path)
    print("PASS: repeated first line of old_text (full block only later)")
end

----------------------------------------------------------------------
-- Test 3: multi=true replaces every matching block
----------------------------------------------------------------------
do
    local path = "tai_edit_test_multi.txt"
    local original = table.concat({
        "    log('info')",
        "    do_work(1)",
        "",
        "    log('info')",
        "    do_work(2)",
    }, "\n") .. "\n"

    write_file(path, original)

    local result = tools.edit(path, "    log('info')", "    log('debug')", true)
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)

    -- Both occurrences must be changed.
    local count = 0
    for _ in content:gmatch("log%('debug'%)") do
        count = count + 1
    end
    assert_equals(count, 2, "multi should have updated both log statements")

    -- No original log('info') should remain.
    assert_not_contains(content, "log('info')", "all matching blocks should have been replaced")

    os.remove(path)
    print("PASS: multi=true replaces every occurrence")
end

----------------------------------------------------------------------
-- Test 4: multi omitted / false only changes the first match even when
-- identical blocks exist.
----------------------------------------------------------------------
do
    local path = "tai_edit_test_single_multi.txt"
    local original = "log('info')\nlog('info')\n"
    write_file(path, original)

    local result = tools.edit(path, "log('info')", "log('warn')")  -- multi omitted => single
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)

    -- Only the first one should change.
    assert_contains(content, "log('warn')\nlog('info')", "only first occurrence should be replaced when multi is not true")

    os.remove(path)
    print("PASS: default (non-multi) changes only first matching block")
end

----------------------------------------------------------------------
-- Test 5: no match returns a clear error and does not modify the file
----------------------------------------------------------------------
do
    local path = "tai_edit_test_no_match.txt"
    local original = "keep this\nand this\n"
    write_file(path, original)

    local result = tools.edit(path, "this block does not exist\nanywhere", "replacement")
    assert_contains(result, "Error: could not find old_text block", "should report not-found error")

    local content = read_file(path)
    assert_equals(content, original, "file must be unchanged on no-match")

    os.remove(path)
    print("PASS: no match produces error and leaves file untouched")
end

----------------------------------------------------------------------
-- Test 6: empty old_text still prepends at the top (multi should be irrelevant)
----------------------------------------------------------------------
do
    local path = "tai_edit_test_prepend.txt"
    write_file(path, "existing content\n")

    local result = tools.edit(path, "", "-- header added\n")
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)
    -- Check that the new content appears at the very beginning of the file.
    if content:sub(1, # "-- header added") ~= "-- header added" then
        print("FAIL: empty old_text should insert at the very start")
        failures = failures + 1
    end

    os.remove(path)
    print("PASS: empty old_text prepends at start of file")
end

----------------------------------------------------------------------
-- Test 7: whitespace normalization tolerance
-- The old_text the agent sends may have different indentation than the file.
-- We should still match and replace correctly.
----------------------------------------------------------------------
do
    local path = "tai_edit_test_norm_ws.txt"
    local original = "    if cond then\n        do_work()\n    end\n"
    write_file(path, original)

    -- Note different leading whitespace in the old_text we supply.
    local old_block = "  if cond then\n    do_work()\n  end"
    local new_block = "  if cond then\n    do_work_v2()\n  end"

    local result = tools.edit(path, old_block, new_block)
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)
    assert_contains(content, "do_work_v2()", "whitespace-normalized match should have succeeded")
    assert_not_contains(content, "do_work()", "original body should have been replaced")

    os.remove(path)
    print("PASS: whitespace normalization allows tolerant matching")
end

----------------------------------------------------------------------
-- Test 8: multi with whitespace-normalized repeated blocks
----------------------------------------------------------------------
do
    local path = "tai_edit_test_multi_norm.txt"
    local original = "  foo()\n  bar()\n\n    foo()\n    bar()\n"
    write_file(path, original)

    -- Different indentation in the provided old_text, same logical block.
    local result = tools.edit(path, "foo()\nbar()", "FOO()\nBAR()", true)
    assert_equals(result, "Patched " .. path)

    local content = read_file(path)
    local count = 0
    local pat = "FOO%(%)" .. "\n" .. "BAR%(%)"
    for _ in content:gmatch(pat) do
        count = count + 1
    end
    assert_equals(count, 2, "multi + normalized ws should replace both blocks")

    os.remove(path)
    print("PASS: multi works together with whitespace normalization")
end

print("\n=== done ===")

if failures == 0 then
    print("All edit tests PASSED")
else
    print(failures .. " test(s) FAILED")
    os.exit(1)
end
