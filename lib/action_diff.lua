-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:diff — drift REPORTING, never writing. Same inputs as dots:apply
-- (root | files, dest, target); walks/plans identically, then reports:
-- content drift as unified diffs, mode drift as one line per file. The
-- human report (two sections, contents first) is printed to stdout; the
-- structured items stay machine-readable in `out`.

local plan = require("./plan")
local diff = require("./diff")

local M = {}

local function fail(msg)
	return { err = "dots:diff: " .. msg }
end

--- Report drift for a tree (root) or a pre-built entry list (files).
--- Never touches the destination for writing.
function M.diff(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end
	if with.root ~= nil and with.files ~= nil then
		return fail("give 'root' or 'files', not both")
	end
	local entries, root
	if with.root ~= nil then
		if type(with.root) ~= "string" or with.root == "" then
			return fail("'root' must be a non-empty string")
		end
		local ok, res = pcall(plan.tree, with.root, { dest = with.dest or "~", override = with.override })
		if not ok then
			return fail("walk of '" .. with.root .. "' failed: " .. tostring(res))
		end
		entries, root = res, with.root
	elseif with.files ~= nil then
		if type(with.files) ~= "table" then
			return fail("'files' must be a list of entry tables")
		end
		entries = with.files
	else
		return fail("one of 'root' (a source tree) or 'files' (an entry list) is required")
	end

	local target = with.target or makac.host
	local report = diff.report(entries, root, target)

	local out = { entries = report.items, differing = {}, mode_drift = {}, ok = {}, skipped = {}, failed = {} }
	for _, it in ipairs(report.items) do
		if it.skipped then
			out.skipped[#out.skipped + 1] = it.dest
		elseif it.err then
			out.failed[#out.failed + 1] = { path = it.dest, err = it.err }
		else
			if it.content then out.differing[#out.differing + 1] = it.dest end
			if it.mode then out.mode_drift[#out.mode_drift + 1] = it.dest end
			if not it.content and not it.mode then out.ok[#out.ok + 1] = it.dest end
		end
	end

	-- reporting changes nothing: changed is fixed false (convention per the
	-- built-in facts action); the drift signal lives in out
	out.drifted = (#out.differing > 0) or (#out.mode_drift > 0)
	local text = diff.render(report.items)
	if text ~= "" then io.stdout:write(text .. "\n") end
	return { changed = false, out = out }
end

return M
