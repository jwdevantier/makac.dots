-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- lib/classify.lua — three-way reconciliation classification. For each plan
-- entry compare three versions of the same path:
--
--   deployed  what dots:apply last deployed (lib/snapshot.lua entry)
--   source    what apply would deploy NOW (post-render desired bytes)
--   target      what sits at the destination right now
--
-- Pure mechanism: no prompting, no policy, no writes. Callers (apply's
-- fast-forward decision, dots:diff, the integrate frontend) act on the
-- returned state.
--
-- States (content):
--   converged          target == deployed == source      — nothing to do
--   ff                 target == deployed, source moved  — fast-forward:
--                      the target file was never user-edited, so applying the
--                      new source is safe EVEN under override = false
--   target-only          target edited, source unchanged   — user edits target;
--                      report, never silently clobber
--   diverged           both moved apart                — genuine conflict
--   new                no target node (deploy fresh; when meta ~= nil the
--                      user deleted a tracked file — a form of target edit)
--   absent-pending     entry wants removal and a target node and/or snapshot
--                      entry exists
--
-- With NO snapshot entry the fall back is the classic 2-way compare the
-- primitives do today:
--   untracked-same     target exists, bytes match source    (== ok)
--   untracked-conflict target exists, bytes differ          (== conflict)
--
-- Kind mismatch (file entry over a target dir and friends) is NOT a state —
-- it is reported in kind_mismatch; the state stays the closest content
-- reading (untracked-conflict/diverged) so apply's conflict semantics hold.
-- Attrs drift (mode/owner) is reported via mode_drift/owner_drift and does
-- NOT change the content state.
--
-- CHEAP PATH: classification runs on hashes — one remote_sha256 of the target
-- path (never a target-bytes fetch), one snapshot.read of the store entry.
-- Source bytes are computed only when a state decision needs the source
-- hash (i.e. a target node exists); hashes classify, the bytes ride along
-- only for merging.
--
-- Entry shape: the same entries dots:apply feeds its inner steps —
-- `relpath` (relative to dest_root, REQUIRED — the walk sets it; files=
-- callers must too) or derivable from a dest under the dest_root prefix.
-- `root` must be set when `src` is relative (same contract as dots:file);
-- entries taken straight from plan.tree lack it — pass the tree root as
-- opts.root and it is used instead.

local materialize = require("./materialize")
local snapshot = require("./snapshot")

local M = {}

-- split from hashes: target/source relative to the deployed hash (nil when
-- untracked)
local function content_state(dsha, target_sha, ssha)
	if dsha == nil then
		return (target_sha == ssha) and "untracked-same" or "untracked-conflict"
	end
	if target_sha == dsha then
		return (ssha == dsha) and "converged" or "ff"
	end
	return (ssha == dsha) and "target-only" or "diverged"
end

--- Classify one entry. opts.root: the tree root for src-relative entries
--- (entry.root wins when set). Returns (result) or (nil, err). Never writes
--- to the target, never raises.
function M.one(target, dest_root, entry, opts)
	if type(entry) ~= "table" then
		return nil, "classify: entry must be a table"
	end
	local entry_root = (entry.root ~= nil) and entry.root or (opts and opts.root)
	if type(dest_root) ~= "string" or dest_root == "" then
		return nil, "classify: dest_root is required and must be a non-empty string"
	end
	dest_root = dest_root:gsub("/+$", "")
	if dest_root == "" then dest_root = "/" end

	local relpath = entry.relpath
	if relpath == nil then
		-- fall back to deriving it from the dest prefix
		local prefix = (dest_root == "/") and "/" or (dest_root .. "/")
		if type(entry.dest) == "string"
			and entry.dest:sub(1, #prefix) == prefix
			and #entry.dest > #prefix then
			relpath = entry.dest:sub(#prefix + 1)
		end
	end
	if type(relpath) ~= "string" or relpath == "" then
		return nil, ("classify: entry '%s' has no relpath relative to '%s' "
				.. "(set entry.relpath, or use a dest under the dest root)")
			:format(tostring(entry.dest), dest_root)
	end

	if type(entry.dest) ~= "string" or entry.dest == "" then
		return nil, "classify: entry.dest is required and must be a non-empty string"
	end
	if entry.dir then
		return nil, "classify: dir entries are not supported (yet)"
	end

	local dest_path, perr = materialize.resolve(target, entry.dest)
	if not dest_path then return nil, tostring(perr) end

	local res = {
		entry = entry,
		relpath = relpath,
		dest_path = dest_path,
		mode_drift = false,
		owner_drift = false,
		kind_mismatch = nil,
	}

	local kind, kerr = materialize.remote_kind(target, dest_path)
	if not kind then return nil, tostring(kerr) end

	-- deployed: the snapshot entry (one store fetch); a CORRUPT entry is an
	-- error — guessing from a damaged deployed version risks misclassifying
	-- target edits as safe fast-forwards
	local se, serr = snapshot.read(target, dest_root, relpath)
	if se == nil and serr ~= nil then
		return nil, "classify: snapshot for '" .. relpath .. "': " .. serr
	end
	res.meta = se and se.meta or nil
	res.deployed = se and se.body or nil
	local dsha = se and se.meta.sha256 or nil

	-- ---- entries requesting removal
	if entry.absent then
		if kind == "file" then
			local lsha, lerr = materialize.remote_sha256(target, dest_path)
			if not lsha then return nil, tostring(lerr) end
			res.target_sha = lsha
		elseif kind == "link" then
			local cur, lerr = materialize.readlink(target, dest_path)
			if not cur then return nil, tostring(lerr) end
			res.target_sha = makac.sha256(cur)
		end
		if kind == "absent" and se == nil then
			res.state = "converged" -- nothing target, nothing recorded
		else
			res.state = "absent-pending"
			if kind == "dir" or kind == "other" then
				-- absent entries never remove directories: surface it
				res.kind_mismatch = kind
			end
		end
		return res
	end

	-- ---- symlink entries: "content" is the stored target string
	if entry.link ~= nil then
		res.source = entry.link
		if kind == "absent" then
			res.state = "new"
			return res
		end
		if kind ~= "link" then
			res.kind_mismatch = kind
			-- dots:link refuses to replace a real node: a conflict
			res.state = (dsha ~= nil) and "diverged" or "untracked-conflict"
			return res
		end
		local cur, lerr = materialize.readlink(target, dest_path)
		if not cur then return nil, tostring(lerr) end
		res.target_sha = makac.sha256(cur)
		res.state = content_state(dsha, res.target_sha, makac.sha256(entry.link))
		return res
	end

	-- ---- plain/templated file entries
	if kind == "absent" then
		-- nothing target: deploy fresh. No target hash, and no source bytes
		-- fetched (nothing to compare against — the caller materializes
		-- when it actually writes)
		res.state = "new"
		return res
	end
	if kind ~= "file" then
		-- a target dir/link/other under a file entry: bytes can't compare —
		-- exists-and-differs semantics; dots:file decides (dirs it refuses)
		res.kind_mismatch = kind
		res.state = (dsha ~= nil) and "diverged" or "untracked-conflict"
		return res
	end

	-- target file: its content hash is the ONLY target touch
	local target_sha, lerr = materialize.remote_sha256(target, dest_path)
	if not target_sha then return nil, tostring(lerr) end
	res.target_sha = target_sha

	-- source: what apply would deploy now (host-side render; needed for the
	-- source-vs-deployed hash split)
	local source, s2err = materialize.desired_bytes(entry, entry_root)
	if not source then return nil, tostring(s2err) end
	res.source = source
	res.state = content_state(dsha, target_sha, makac.sha256(source))

	-- attrs drift is orthogonal to content state
	if entry.mode ~= nil then
		local rm, merr = materialize.remote_mode(target, dest_path)
		if not rm then return nil, tostring(merr) end
		res.mode_drift = not materialize.mode_eq(rm, entry.mode)
	end
	if entry.owner ~= nil then
		local ro, oerr = materialize.remote_owner(target, dest_path)
		if not ro then return nil, tostring(oerr) end
		res.owner_drift = not materialize.owner_eq(ro, entry.owner)
	end
	return res
end

--- Classify a list of entries, in order (opts.root threads into each).
--- Per-entry failures are reported IN PLACE as `{ err = msg, entry = ... }`
--- (state unset) — one bad entry never hides the classification of the rest.
function M.all(target, dest_root, entries, opts)
	if type(entries) ~= "table" then
		return nil, "classify: entries must be a list"
	end
	local out = {}
	for i, entry in ipairs(entries) do
		local r, err = M.one(target, dest_root, entry, opts)
		if r == nil then
			out[i] = { err = err, entry = entry }
		else
			out[i] = r
		end
	end
	return out
end

return M
