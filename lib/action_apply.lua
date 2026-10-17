-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:apply — the primary action. Walks with.root (or takes the with.files
-- escape hatch) into an entry list via lib/plan.lua and issues one inner
-- `step{uses="dots:file"|"dots:link", name=entry.dest, with=entry}` per
-- entry, so every file logs its own ok/changed/skipped/failed line.
--
-- Failure semantics (the workflow decides fatality):
-- - EVERY entry is visited regardless of individual failures (each inner
--   step is pcall'd — step() raises on action failure).
-- - per-file failure is DATA in out.failed, so `err` stays UNSET even when
--   failures occurred; only with.strict = true turns failures into `err`.
-- - changed = true iff at least one file changed.
-- - with.check = true propagates to each inner step: changed-ness is
--   computed from hashes, nothing is written; conflicts still count as
--   failures (a conflict means the current state cannot converge).

local plan = require("./plan")

local M = {}

local function fail(msg)
	return { err = "dots:apply: " .. msg }
end

--- Apply an entry list to a target. The result-shape contract is
--- documented in README.md.
function M.apply(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end

	local dest = with.dest or "~"
	local check = with.check == true
	local strict = with.strict == true

	-- root is the normal input; files (a pre-built entry list) is the escape
	-- hatch. root wins when both are given.
	local entries
	if with.root ~= nil then
		if type(with.root) ~= "string" or with.root == "" then
			return fail("'root' must be a non-empty string")
		end
		local ok, res = pcall(plan.tree, with.root, { dest = dest, override = with.override })
		if not ok then
			return fail("walk of '" .. with.root .. "' failed: " .. tostring(res))
		end
		entries = res
	elseif with.files ~= nil then
		if type(with.files) ~= "table" then
			return fail("'files' must be a list of entry tables")
		end
		entries = with.files
	else
		return fail("one of 'root' (a source tree) or 'files' (an entry list) is required")
	end

	local ok_paths, changed_paths, failed, skipped = {}, {}, {}, {}
	local any_changed = false

	for i, entry in ipairs(entries) do
		if type(entry) ~= "table" then
			return fail(("entry #%d is not a table"):format(i))
		end
		local ename = entry.dest or tostring(entry.src or ("entry #" .. i))
		-- copy the entry and impose the call-site policy: check propagates,
		-- a nil per-entry override takes the call-site override, the outer
		-- target threads into every inner step (inner steps do not inherit
		-- the surrounding step's target by themselves).
		local iw = {}
		for k, v in pairs(entry) do iw[k] = v end
		if iw.override == nil then
			iw.override = with.override == true
		end
		if check then
			iw.check = true
		end
		if with.root ~= nil then
			-- walk entries carry src RELATIVE to root; the primitive resolves
			-- it against with.root
			iw.root = with.root
		end
		iw.target = with.target

		local uses = (iw.link ~= nil) and "dots:link" or "dots:file"
		local sok, r = pcall(step, { uses = uses, name = ename, with = iw })
		if not sok then
			-- step() already logged the failed line; record the failure and
			-- CONTINUE — one failed file never stops the loop.
			failed[#failed + 1] = { path = ename, err = tostring(r) }
			-- the REASON must not be lost: err stays unset on the outer step
			-- (non-fatal by design) so makac itself prints nothing about why
			io.stderr:write(("dots:apply: %s: %s\n"):format(ename, tostring(r)))
		elseif r.skipped then
			skipped[#skipped + 1] = ename
		else
			if r.changed then
				any_changed = true
				changed_paths[#changed_paths + 1] = ename
			else
				ok_paths[#ok_paths + 1] = ename
			end
		end
	end

	local out = {
		changed = changed_paths,
		ok = ok_paths,
		failed = failed,
		skipped = skipped,
	}
	local res = { changed = any_changed, out = out }
	if strict and #failed > 0 then
		res.err = ("strict: %d of %d entries failed"):format(#failed, #entries)
	end
	return res
end

return M
