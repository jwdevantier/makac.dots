-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:prune — converge the on-target snapshot store with the current plan:
-- find entries this tree deployed that are no longer in the plan (orphans)
-- and act on them according to with.policy. NON-INTERACTIVE: this action
-- never prompts; the interactive D/F/S frontend lives in makac.mydots.
--
-- Policy:
--   "report" (default)  — no mutation; everything is output. Vanished
--                         orphans are listed as would_forget, target ones as
--                         would_delete.
--   "delete"            — remove the target file AND drop the snapshot entry.
--                         Drift (user edits since deploy) is reported but
--                         does NOT stop the delete: the policy was explicit.
--   "forget"            — drop the snapshot entry only; target files stay.
-- Regardless of policy, orphans whose target node already VANISHED are
-- auto-forgotten (nothing to delete; prompting would be noise).
-- check = true behaves exactly like "report", whatever the policy.
--
-- Entries owned by OTHER trees are never touched: they are counted and
-- reported as foreign ("N entries owned by 'bootstrap' — skipped").
-- Directories are never removed. The delete-safety signal (drift) comes
-- from the snapshot: target bytes are hashed and compared with what was last
-- deployed.
--
-- Failure semantics mirror dots:apply: per-orphan failures are DATA in
-- out.failed and never abort the run; only strict = true turns them into
-- err. changed = true iff anything was deleted or forgotten.

local plan = require("./plan")
local prune = require("./prune")

local M = {}

local function fail(msg)
	return { err = "dots:prune: " .. msg }
end

local function resolve_target(with)
	if with.target == nil then
		return makac.host
	end
	local ok, t = pcall(makac.resolve_target, with)
	if not ok then return nil, tostring(t) end
	return t
end

local function note(fmt, ...)
	io.stderr:write(("dots:prune: " .. fmt .. "\n"):format(...))
end

--- Prune snapshot entries that fell out of the plan. The result-shape
--- contract is documented in README.md.
function M.prune(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end
	local dest = (with.dest or "~"):gsub("/+$", "")
	if dest == "" then
		return fail("'dest' must not be empty")
	end
	if type(with.root) ~= "string" or with.root == "" then
		return fail("'root' (a source tree) is required")
	end
	if with.tree ~= nil and (type(with.tree) ~= "string" or with.tree == "") then
		return fail("'tree' (the owner id) must be a non-empty string")
	end
	local policy = with.policy or "report"
	if policy ~= "report" and policy ~= "delete" and policy ~= "forget" then
		return fail("'policy' must be \"report\" (default), \"delete\", or \"forget\"")
	end
	local report_only = with.check == true or policy == "report"

	-- Owner identity, same precedence as dots:apply: with.tree > $tree in the
	-- root dots.lua > basename(root).
	local ok, entries, dtree = pcall(plan.tree, with.root, { dest = dest })
	if not ok then
		return fail("walk of '" .. with.root .. "' failed: " .. tostring(entries))
	end
	local base = (with.root:gsub("/+$", "")):match("[^/]+$") or "/"
	local tree = with.tree or dtree or base

	-- planned relpaths (dest-relative). Walk entries carry relpath (the
	-- root's '.' entry carries "."); the dest-prefix strip is the fallback.
	-- Skipped (skip=true) entries still count as planned: they are in the
	-- tree on purpose, so their snapshot entries — if any — are not orphans.
	local prefix = (dest == "/") and "/" or (dest .. "/")
	local planned = {}
	for _, e in ipairs(entries) do
		local rel = e.relpath
		if rel == nil and type(e.dest) == "string" and e.dest:sub(1, #prefix) == prefix then
			rel = e.dest:sub(#prefix + 1)
			if rel == "" then rel = nil end
		end
		if rel ~= nil then planned[#planned + 1] = rel end
	end

	local target, terr = resolve_target(with)
	if not target then
		return fail("cannot resolve target: " .. tostring(terr))
	end

	local res, oerr = prune.orphans(target, dest, tree, planned)
	if not res then
		return fail(oerr)
	end

	for _, o in ipairs(res.orphans) do
		local tag
		if o.target_kind == nil then
			tag = "target node gone — auto-forget"
		elseif o.meta.kind == "dir" then
			tag = ("target %s, %s%s"):format(o.target_kind,
				o.empty == false and "NON-EMPTY" or "empty",
				o.drifted and ", ATTRS DRIFTED" or "")
		else
			tag = ("target %s%s"):format(o.target_kind, o.drifted and ", DRIFTED (user edits)" or "")
		end
		note("orphan %s (%s)", o.relpath, tag)
	end
	for _, f in ipairs(res.foreign) do
		note("%d %s owned by '%s' — skipped", f.count,
			f.count == 1 and "entry" or "entries", f.tree)
	end

	local out = {
		orphans = res.orphans,
		foreign = res.foreign,
		vanished = {},
		deleted = {},
		forgotten = {},
		skipped_dirs = {},
		failed = {},
	}
	local any_changed = false
	for _, o in ipairs(res.orphans) do
		if o.target_kind == nil then
			out.vanished[#out.vanished + 1] = o.relpath
		end
	end

	local function decide(o, decision)
		local sok, dres, derr = pcall(prune.apply_decision, target, dest, o, decision)
		if not sok then
			out.failed[#out.failed + 1] = { path = o.relpath, err = tostring(dres) }
			note("%s: %s", o.relpath, tostring(dres))
			return
		end
		if dres == nil then
			out.failed[#out.failed + 1] = { path = o.relpath, err = tostring(derr) }
			note("%s: %s", o.relpath, tostring(derr))
			return
		end
		any_changed = true
		if decision == "delete" then
			out.deleted[#out.deleted + 1] = { relpath = o.relpath, drifted = o.drifted }
		else
			out.forgotten[#out.forgotten + 1] = o.relpath
		end
	end

	if report_only then
		out.would_delete = {}
		out.would_forget = {}
		for _, o in ipairs(res.orphans) do
			if o.target_kind == nil then
				out.would_forget[#out.would_forget + 1] = o.relpath
			else
				out.would_delete[#out.would_delete + 1] = { relpath = o.relpath, drifted = o.drifted }
			end
		end
	elseif policy == "delete" then
		for _, o in ipairs(res.orphans) do
			if o.target_kind == nil then
				decide(o, "forget") -- nothing to delete: auto-forget
			elseif o.meta.kind == "dir" and o.target_kind == "dir" and o.empty == false then
				-- non-empty orphaned dir: REPORT, never touch — prune removes
				-- only EMPTY directories (rmdir; recursion is impossible)
				out.skipped_dirs[#out.skipped_dirs + 1] = o.relpath
				note("%s: non-empty orphaned directory — kept (prune removes only empty dirs)", o.relpath)
			else
				decide(o, "delete")
			end
		end
	elseif policy == "forget" then
		for _, o in ipairs(res.orphans) do
			decide(o, "forget")
		end
	end

	-- summary lines (details were printed per-orphan above)
	if #out.vanished > 0 then note("%d vanished %s", #out.vanished, #out.vanished == 1 and "entry" or "entries") end
	if #out.deleted > 0 then note("deleted %d target %s", #out.deleted, #out.deleted == 1 and "file" or "files") end
	if #out.forgotten > 0 then note("forgot %d %s", #out.forgotten, #out.forgotten == 1 and "entry" or "entries") end
	if #out.skipped_dirs > 0 then note("kept %d non-empty %s", #out.skipped_dirs,
		#out.skipped_dirs == 1 and "directory" or "directories") end

	local r = { changed = any_changed, out = out }
	if with.strict == true and #out.failed > 0 then
		r.err = ("strict: %d of %d orphans failed"):format(#out.failed, #res.orphans)
	end
	return r
end

return M
