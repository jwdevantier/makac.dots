-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- lib/prune.lua — the prune MECHANISM: find on-target snapshot entries that
-- no longer appear in the current plan (orphans) and apply delete/forget
-- decisions to them. Deterministic and TTY-free: this module NEVER prompts
-- and never prints — it returns data. The interactive frontend lives in
-- makac.mydots; the non-interactive action frontend is lib/action_prune.lua.
--
-- Orphans are entries whose tree == the caller's owner id and whose relpath
-- is not in the current plan. Entries owned by OTHER trees are reported
-- (grouped by owner id) and never touched.
--
-- All target IO goes through lib/materialize.lua; snapshot IO through
-- lib/snapshot.lua.

local materialize = require("./materialize")
local snapshot = require("./snapshot")

local M = {}

-- Join dest root + relpath (dest root is already resolved here; "/" must
-- not become "//").
local function join(dest_root, relpath)
	local base = dest_root:gsub("/+$", "")
	if base == "" then base = "/" end
	return base .. "/" .. relpath
end

--- Orphans = snapshot entries with tree == mine, minus the planned relpaths.
--- planned_relpaths is a LIST of relpaths (relative to dest_root).
---
--- Returns
---   {
---     orphans = {
---       { relpath=..., meta=...,          -- the snapshot header
---         target_kind=<"file"|"link"|...|nil>,  -- nil: the target node vanished
---         drifted=<bool>,                 -- target bytes/repointed link differ
---                                         --   from what was deployed; for
---                                         --   dirs: recorded mode/owner drift
---         empty=<bool|nil>,               -- dir orphans only: target dir empty
---       }, ...
---     },
---     foreign = { { tree=..., count=N }, ... },  -- other owners, never touched
---   }
--- or (nil, err) — a corrupt store or a failed target check is LOUD, never
--- guessed around (prune deletes real files on the strength of this data).
function M.orphans(target, dest_root, tree, planned_relpaths)
	if type(tree) ~= "string" or tree == "" then
		return nil, "prune.orphans: tree (owner id) must be a non-empty string"
	end
	if type(planned_relpaths) ~= "table" then
		return nil, "prune.orphans: planned_relpaths must be a list of relpaths"
	end
	local planned = {}
	for _, r in ipairs(planned_relpaths) do planned[r] = true end

	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end

	local entries, lerr = snapshot.list(target, dest_root)
	if not entries then return nil, lerr end

	local orphans = {}
	local foreign = {} -- owner id -> count
	for _, e in ipairs(entries) do
		local meta = e.meta
		if meta.tree ~= tree then
			foreign[meta.tree] = (foreign[meta.tree] or 0) + 1
		elseif not planned[e.relpath] then
			local target_path = join(root, e.relpath)
			local target_kind, kerr = materialize.remote_kind(target, target_path)
			if not target_kind then
				return nil, ("checking target node for orphan %q: %s"):format(e.relpath, kerr)
			end
			if target_kind == "absent" then target_kind = nil end
			local drifted = false
			local empty = nil
			if target_kind ~= nil then
				if meta.kind == "dir" then
					-- directories carry no bytes: drift = recorded mode/owner vs
					-- target attrs; emptiness decides whether delete is even possible
					if target_kind == "dir" then
						local names, derr = materialize.readdir(target, target_path)
						if not names then
							return nil, ("listing orphan dir %q: %s"):format(e.relpath, derr)
						end
						empty = #names == 0
						if meta.mode ~= nil then
							local have = materialize.remote_mode(target, target_path)
							if have and not materialize.mode_eq(have, meta.mode) then
								drifted = true
							end
						end
						if meta.owner ~= nil and not drifted then
							local have = materialize.remote_owner(target, target_path)
							if have and not materialize.owner_eq(have, meta.owner) then
								drifted = true
							end
						end
					else
						-- a deployed directory whose target node is no longer a dir
						drifted = true
					end
				elseif meta.kind == "link" then
					-- drift = the link was replaced or now points elsewhere.
					-- (For links the stored sha256 is of the target STRING, so
					-- the comparison goes through readlink, not the generic
					-- remote_sha256 path below.)
					if target_kind == "link" then
						local lt, lerr2 = materialize.readlink(target, target_path)
						if not lt then
							return nil, ("readlink orphan %q: %s"):format(e.relpath, lerr2)
						end
						drifted = makac.sha256(lt) ~= meta.sha256
					else
						drifted = true
					end
				elseif target_kind == "file" then
					local sha, serr = materialize.remote_sha256(target, target_path)
					if not sha then
						return nil, ("hashing orphan %q: %s"):format(e.relpath, serr)
					end
					drifted = sha ~= meta.sha256
				else
					-- a deployed file whose target node became a dir/link/other
					-- is definitionally drifted
					drifted = true
				end
			end
			orphans[#orphans + 1] = {
				relpath = e.relpath,
				meta = meta,
				target_kind = target_kind,
				drifted = drifted,
				empty = empty,
			}
		end
	end

	local f = {}
	for owner, count in pairs(foreign) do
		f[#f + 1] = { tree = owner, count = count }
	end
	table.sort(f, function(a, b) return a.tree < b.tree end)
	return { orphans = orphans, foreign = f }
end

--- Apply one decision to one orphan (a table as produced by M.orphans):
---   "delete"  — remove the target node AND drop the snapshot entry. Files
---               and links go via materialize.remove_path; DIRECTORIES go
---               via rmdir and ONLY when empty — non-empty dirs refuse
---               loudly (there is deliberately no recursive removal in the
---               target interface).
---   "forget"  — drop the snapshot entry only (the target node is left alone).
---
--- Returns ({ relpath=..., decision=..., removed_live=<bool> }) or
--- (nil, err). Never prompts, never prints.
function M.apply_decision(target, dest_root, orphan, decision)
	if type(orphan) ~= "table" or type(orphan.relpath) ~= "string" or orphan.relpath == "" then
		return nil, "prune.apply_decision: orphan must have a relpath"
	end
	if type(orphan.meta) ~= "table" then
		return nil, "prune.apply_decision: orphan must carry its snapshot meta"
	end
	if decision ~= "delete" and decision ~= "forget" then
		return nil, "prune.apply_decision: decision must be 'delete' or 'forget'"
	end

	local is_dir = orphan.meta.kind == "dir"

	-- resolve the target path/kind up front (the caller may pass a bare orphan
	-- table with no target_kind — recompute in that case)
	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end
	local target_path = join(root, orphan.relpath)
	local target_kind = orphan.target_kind
	if target_kind == nil then
		local k, kerr = materialize.remote_kind(target, target_path)
		if not k then return nil, kerr end
		if k ~= "absent" then target_kind = k end
	end

	local removed_live = false
	if decision == "delete" and target_kind ~= nil then
		if is_dir then
			if target_kind ~= "dir" then
				return nil, ("prune: target node for directory entry %q is a %s — "
					.. "refusing to remove it"):format(orphan.relpath, target_kind)
			end
			-- re-check emptiness at decision time (do not trust a possibly
			-- stale orphan.empty); rmdir itself also refuses non-empty dirs,
			-- but a loud, specific error beats a bare syscall message
			local names, derr = materialize.readdir(target, target_path)
			if not names then return nil, derr end
			if #names > 0 then
				return nil, ("prune: target directory for %q is not empty — "
					.. "only empty directories are removed (never recursively)")
					:format(orphan.relpath)
			end
			local ok, err = materialize.rmdir(target, target_path)
			if not ok then
				return nil, ("prune: rmdir of %q failed: %s"):format(orphan.relpath, err)
			end
			removed_live = true
		else
			if target_kind == "dir" then
				return nil, ("prune: target node for %q is a directory — refusing "
					.. "to remove it"):format(orphan.relpath)
			end
			local ok, err = materialize.remove_path(target, target_path)
			if not ok then
				return nil, ("prune: removing target %q failed: %s"):format(orphan.relpath, err)
			end
			removed_live = true
		end
	end

	-- no graveyard: a pruned entry is DROPPED, and a lost drop must surface
	-- (a stale entry would keep offering the same orphan forever)
	local ok, err = snapshot.remove(target, dest_root, { orphan.relpath })
	if not ok then
		return nil, ("prune: dropping snapshot entry for %q failed: %s")
			:format(orphan.relpath, err)
	end
	return { relpath = orphan.relpath, decision = decision, removed_live = removed_live }
end

return M
