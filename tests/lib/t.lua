-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- Minimal assertion helper for the unit tests. Usage:
--   local t = dofile(SCRIPT_DIR .. "/lib/t.lua")
--   t.case("name", function() t.eq(got, want) end)
--   t.done()  -- prints summary, prints FAIL + aborts on any failure

local T = { passed = 0, failed = 0, cases = 0, case_failed = false }

local function show(v)
	if type(v) == "string" then return ("%q"):format(v) end
	return tostring(v)
end

function T.fail(msg)
	T.failed = T.failed + 1
	T.case_failed = true
	print("    FAIL: " .. msg)
end

function T.pass()
	T.passed = T.passed + 1
end

function T.truthy(v, msg)
	if v then
		T.pass()
	else
		T.fail((msg or "expected truthy") .. " (got " .. show(v) .. ")")
	end
end

function T.eq(got, want, msg)
	if got == want then
		T.pass()
	else
		T.fail((msg or "values differ") .. ": got " .. show(got) .. ", want " .. show(want))
	end
end

function T.contains(hay, needle, msg)
	if type(hay) == "string" and hay:find(needle, 1, true) ~= nil then
		T.pass()
	else
		T.fail((msg or "string does not contain needle") .. ": " .. show(hay) ..
			" lacks " .. show(needle))
	end
end

--- Run fn as a named case; a raised error fails the case, not the run.
function T.case(name, fn)
	T.cases = T.cases + 1
	T.case_failed = false
	local ok, err = pcall(fn)
	if not ok then
		T.fail("case raised: " .. tostring(err))
	end
	print((T.case_failed and "  not ok " or "  ok     ") .. name)
end

--- Print the summary; abort (non-zero exit) when anything failed.
function T.done()
	print(("unit: %d cases, %d assertions passed, %d failed"):format(T.cases, T.passed, T.failed))
	if T.failed > 0 then
		print("FAIL")
		error("unit test failures", 0)
	end
	print("PASS")
end

return T
