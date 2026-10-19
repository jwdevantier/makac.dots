-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:apply — the primary action. Walks with.root (or takes the with.files
-- escape hatch) into an entry list via lib/plan.lua and issues one inner
-- `step{uses="dots:file"|"dots:link", name=entry.dest, with=entry}` per
-- entry, so every file logs its own ok/changed/skipped/failed line.
--
-- CLASSIFICATION: every tracked entry is classified (lib/classify.lua)
-- BEFORE its inner step is dispatched. Classification decides WHETHER to
-- dispatch and how the result is labelled — never HOW to write (writes
-- always go through the primitives):
--   converged / untracked-* / new / absent-pending  → dispatch as-is
--   ff (target == deployed, only source moved)        → dispatch with a
--     forced inner override: the target file was never user-edited, so it
--     fast-forwards even when override = false
--   target-only (user edited target, source unchanged)  → override = false:
--     NO write; the entry is reported in out.target_only (neither changed
--     nor failed). override = true: dispatch, overwriting the user edits
--     — that is precisely what the flag now means.
--   diverged                                        → dispatch as-is: with
--     override = false the primitive conflicts (data in out.failed).
-- check mode still classifies (read-only) and reports what would fast-
-- forward / be skipped / conflict; nothing is written or recorded.
--
-- dots:apply OWNS SNAPSHOT RECORDING (the primitives stay pure): after each
-- successful inner step it writes/drops the on-target snapshot entry via
-- lib/snapshot.lua, so prune/integrate always know what was last deployed.
-- A lost snapshot write never fails a step (pcall-guarded, warns on stderr);
-- check mode records nothing. An entry is tracked iff it came from a walked
-- tree (with.root), or from with.files when with.tree is given AND its dest
-- sits under the apply dest prefix. Bare dots:file calls never snapshot.
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
local materialize = require("./materialize")
local snapshot = require("./snapshot")
local classify = require("./classify")

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

	local dest = (with.dest or "~"):gsub("/+$", "")
	if dest == "" then
		return fail("'dest' must not be empty")
	end
	local check = with.check == true
	local strict = with.strict == true
	-- frontends that present failures themselves (mydots' CLI) pass
	-- quiet = true: out.failed stays identical, but the per-entry stderr
	-- chatter (which would just be re-printed by the frontend) is skipped
	local quiet = with.quiet == true
	-- manage_dest_dir acknowledges the ROOT ["."] footgun: mode/owner on the
	-- DEST prefix itself (usually "~"). Walked root dir entries fail without
	-- it (see dots:dir); bare dots:dir calls never need the flag.
	local manage_dest_dir = with.manage_dest_dir == true
	if with.tree ~= nil and (type(with.tree) ~= "string" or with.tree == "") then
		return fail("'tree' (the owner id) must be a non-empty string")
	end

	-- Owner identity, resolved ONCE per apply (baked into every snapshot
	-- entry): with.tree > $tree in the root dots.lua > basename(root). For
	-- files= there is no walk, so only with.tree counts — and without it the
	-- entries are untracked (no snapshot, no prune/integrate coverage).
	local tree = nil

	-- root is the normal input; files (a pre-built entry list) is the escape
	-- hatch. Both given is an error (silently picking one would hide a
	-- caller bug), as is neither.
	local entries
	if with.root ~= nil and with.files ~= nil then
		return fail("give 'root' or 'files', not both")
	end
	if with.root ~= nil then
		if type(with.root) ~= "string" or with.root == "" then
			return fail("'root' must be a non-empty string")
		end
		local ok, walked, dtree = pcall(plan.tree, with.root,
			{ dest = dest, override = with.override })
		if not ok then
			return fail("walk of '" .. with.root .. "' failed: " .. tostring(walked))
		end
		entries = walked
		local base = (with.root:gsub("/+$", "")):match("[^/]+$") or "/"
		tree = with.tree or dtree or base
	elseif with.files ~= nil then
		if type(with.files) ~= "table" then
			return fail("'files' must be a list of entry tables")
		end
		entries = with.files
		tree = with.tree
	else
		return fail("one of 'root' (a source tree) or 'files' (an entry list) is required")
	end

	-- Everything tracked lives under the DEST prefix; the snapshot entry name
	-- is the relpath relative to it.
	local prefix = (dest == "/") and "/" or (dest .. "/")
	local function relpath_of(d)
		if type(d) ~= "string" then return nil end
		if d:sub(1, #prefix) ~= prefix then return nil end
		local r = d:sub(#prefix + 1)
		if r == "" then return nil end
		return r
	end
	local tracked_scope = (with.root ~= nil) or (tree ~= nil)

	-- pcall-guarded snapshot IO: a lost snapshot write must NEVER fail the
	-- apply step. Returns the call's own returns after warning on failure.
	local function snap(fn, ...)
		local rs = { pcall(fn, ...) }
		if not rs[1] then
			io.stderr:write(("dots:apply: snapshot: %s\n"):format(tostring(rs[2])))
			return nil
		end
		if rs[2] == nil and rs[3] ~= nil then
			io.stderr:write(("dots:apply: snapshot: %s\n"):format(tostring(rs[3])))
		end
		return table.unpack(rs, 2)
	end

	-- resolved lazily, and only when a snapshot op is actually needed, so a
	-- target resolution failure can never change apply's own semantics
	local snap_target, snap_tried = nil, false
	local function target_for_snapshot()
		if not snap_tried then
			snap_tried = true
			if with.target == nil then
				snap_target = makac.host
			else
				local ok, t = pcall(makac.resolve_target, with)
				if ok then
					snap_target = t
				else
					io.stderr:write(("dots:apply: cannot resolve target for "
						.. "snapshot recording: %s\n"):format(tostring(t)))
				end
			end
		end
		return snap_target
	end

	-- Record one successful inner step. iw is the inner `with` (entry
	-- fields); r is the inner step's result (r.out.path is the RESOLVED
	-- remote path).
	local function record(tgt, rel, iw, r)
		if iw.absent then
			if r.changed then
				-- a removal DROPS the entry — the store never keeps bytes for
				-- a target path that is deliberately gone (no graveyard)
				snap(snapshot.remove, tgt, dest, { rel })
			end
			return
		end
		if iw.dir == true then
			-- directories carry no body (sha256 of the empty string, per the
			-- format). Converged entries with an existing record are left
			-- alone; attr-only changes refresh the recorded mode/owner; a
			-- missing record is backfilled (pre-snapshot deployment).
			local meta = { tree = tree, kind = "dir", mode = iw.mode, owner = iw.owner }
			if not r.changed and snap(snapshot.read, tgt, dest, rel) ~= nil then
				return
			end
			snap(snapshot.write, tgt, dest, rel, meta, "")
			return
		end
		local kind = (iw.link ~= nil) and "link" or "file"
		local meta = { tree = tree, kind = kind, mode = iw.mode, owner = iw.owner }
		if r.out and r.out.deployed_bytes ~= nil then
			-- a real content write: the deployed bytes came back with the step
			snap(snapshot.write, tgt, dest, rel, meta, r.out.deployed_bytes)
			return
		end
		if r.changed then
			-- chmod/chown only: refresh the attrs, keep the recorded body
			local cur = snap(snapshot.read, tgt, dest, rel)
			if cur ~= nil then
				snap(snapshot.write, tgt, dest, rel, meta, cur.body)
				return
			end
			-- no entry (pre-snapshot deployment): fall through to backfill
		end
		-- converged/ok (or attr-only change with no entry): BACKFILL so
		-- pre-snapshot deployments start being tracked without touching the
		-- target file. The bytes are the target (= desired) bytes; for links,
		-- the stored target string.
		if snap(snapshot.read, tgt, dest, rel) ~= nil then return end
		local body
		if kind == "link" then
			body = iw.link
		else
			body = snap(materialize.fetch_bytes, tgt, r.out.path)
		end
		if body == nil then return end
		snap(snapshot.write, tgt, dest, rel, meta, body)
	end

	local ok_paths, changed_paths, failed, skipped, target_only = {}, {}, {}, {}, {}
	local any_changed = false
	local untracked = 0

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

		-- Classify the entry BEFORE dispatch (tracked entries only — bare
		-- files= calls without with.tree have no snapshot base, hence the
		-- 2-way exists-and-differs fallback the primitives already implement).
		-- Read-only, so check mode reports the same states without writing.
		-- Directories are not classifyable (no content): a walked root ["."]
		-- entry additionally carries the DEST-itself gate context down to
		-- dots:dir, and gets the fixed relpath "." for snapshot recording.
		local is_root_dir = iw.dir == true and iw.relpath == "."
		if is_root_dir then
			iw.is_root_dir = true
			iw.manage_dest_dir = manage_dest_dir
		end
		local state = nil
		local rel
		if tracked_scope then
			rel = is_root_dir and "." or relpath_of(iw.dest)
		end
		if rel ~= nil and iw.dir ~= true then
			local tgt = target_for_snapshot()
			if tgt ~= nil then
				local cr, cerr = classify.one(tgt, dest, iw)
				if cr ~= nil then
					state = cr.state
				else
					-- a classify failure (e.g. corrupt snapshot entry) must not
					-- silently untrack the entry: warn and fall back to the
					-- 2-way conflict model, which errs on the safe side
					io.stderr:write(("dots:apply: classify %s: %s\n")
						:format(ename, tostring(cerr)))
				end
			end
		end

		local skip_write = false
		if state == "ff" then
			-- target == deployed, only the source moved: the target file was
			-- never user-edited, so fast-forwarding is safe even under
			-- override = false (override means precisely "may I overwrite
			-- USER EDITS" — there are none here). The write itself still
			-- goes through the normal inner step.
			iw.override = true
		elseif state == "target-only" and not iw.override then
			-- the user edited the target file and the source did not move:
			-- never silently clobber. This is neither a change nor a
			-- failure — report it.
			target_only[#target_only + 1] = ename
			if not quiet then
				io.stderr:write(("dots:apply: %s: user edits on the target file "
					.. "(source unchanged) — not writing; override = true to "
					.. "take the tree's version\n"):format(ename))
			end
			skip_write = true
		end

		if skip_write then
			-- no write, no snapshot change: deployed is (and stays) the
			-- recorded version, source == deployed was just verified
			goto continue
		end

		-- dispatch by entry kind: symlink / directory / regular file
		local uses = (iw.link ~= nil) and "dots:link"
			or (iw.dir == true and "dots:dir" or "dots:file")
		local sok, r = pcall(step, { uses = uses, name = ename, with = iw })
		if not sok then
			-- step() already logged the failed line; record the failure and
			-- CONTINUE — one failed file never stops the loop. Strip step()'s
			-- "step '<name>' (uses '<uses>') failed:" wrapper: out.failed is
			-- DATA, and the name/uses are already on the entry.
			local msg = (tostring(r):gsub("^step '.-' %(uses '.-'%) failed:%s*", ""))
			failed[#failed + 1] = { path = ename, err = msg }
			if not quiet then
				-- the REASON in real time for plain workflow runs (out.failed is
				-- data, but makac prints nothing about it); frontends that present
				-- failures themselves pass with.quiet = true
				io.stderr:write(("dots:apply: %s: %s\n"):format(ename, msg))
			end
		elseif r.skipped then
			skipped[#skipped + 1] = ename
		else
			if r.changed then
				any_changed = true
				changed_paths[#changed_paths + 1] = ename
			else
				ok_paths[#ok_paths + 1] = ename
			end
			if not check and tracked_scope then
				local tgt = rel and target_for_snapshot() or nil
				if tgt ~= nil then
					record(tgt, rel, iw, r)
				else
					untracked = untracked + 1
				end
			end
		end

		::continue::
	end

	if untracked > 0 then
		-- ONE line per apply, not per file: untracked entries deploy fine but
		-- have no snapshot entry, hence no prune/integrate coverage (the
		-- documented behavior of bare dots:file calls).
		io.stderr:write(("dots:apply: %d untracked entr%s (files= without "
			.. "with.tree, or dest outside the dest prefix): deployed, but no "
			.. "snapshot recorded — no prune/integrate coverage\n")
			:format(untracked, untracked == 1 and "y" or "ies"))
	end

	local out = {
		changed = changed_paths,
		ok = ok_paths,
		failed = failed,
		skipped = skipped,
		target_only = target_only,
	}
	local res = { changed = any_changed, out = out }
	if strict and #failed > 0 then
		res.err = ("strict: %d of %d entries failed"):format(#failed, #entries)
	end
	return res
end

return M
