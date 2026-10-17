-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- The tree walk: walk a source tree of files into the entry list every action consumes. This is the producer half — no
-- action semantics live here. All reads are HOST-side (the tree lives in
-- the project repo).
--
-- Settled semantics implemented here (do not reopen):
-- - a dots.lua is the complete, self-contained policy for its own directory;
--   there is no inheritance and no cross-directory merging.
-- - `$default_attrs` carries ATTRIBUTES ONLY, for files in this directory with no
--   explicit entry; `absent`/`skip` inside it are an error.
-- - `$ignore` is a list of glob patterns (lib/glob.lua); matching files are
--   skipped, matching directories are not descended into. `.git`, `.makac`
--   and `dots.lua` are auto-ignored everywhere.
-- - override precedence: per-entry `override` > `$override` (function or
--   boolean) > call-site default (opts.override, default false); the resolved
--   value is baked into each entry at walk time.
-- - empty directories ship nothing; source symlinks are dereferenced unless
--   the entry has `reproduce = true` (then a link entry is synthesized);
--   a broken symlink in dereference mode is a walk error.

local glob = require("./glob")

local M = {}

local AUTO_IGNORE = { [".git"] = true, [".makac"] = true, ["dots.lua"] = true }

--- Load dir's dots.lua policy, if any. Returns the table, or nil when the
--- directory has no dots.lua. Raises on a load error — a broken dots.lua
--- must fail loudly, not be silently skipped.
function M.load_dotsfile(dir)
	local path = dir .. "/dots.lua"
	if makac.fs.stat(path) == nil then
		return nil
	end
	local chunk, lerr = loadfile(path)
	if not chunk then
		error(("plan: cannot load dots.lua '%s': %s"):format(path, tostring(lerr)), 2)
	end
	-- a dots.lua may reference the workflow global PROJECT_DIR; when running
	-- data-dir-less (plain `makac script.lua`) it is nil and such dots.lua
	-- files error here — surface it as a clear load error either way.
	local ok, res = pcall(chunk)
	if not ok then
		error(("plan: dots.lua '%s' failed: %s"):format(path, tostring(res)), 2)
	end
	if type(res) ~= "table" then
		error(("plan: dots.lua '%s' must return a table, got %s"):format(path, type(res)), 2)
	end
	return res
end

-- attributes a dots.lua entry / $default_attrs may carry (copy-through set)
local function merge_attrs(dst, src, what, path)
	if src == nil then
		return
	end
	for k, v in pairs(src) do
		if type(k) ~= "string" or k:sub(1, 1) == "$" then
			error(("plan: %s at '%s': attribute keys must be plain strings not starting with '$'")
				:format(what, path), 3)
		end
		if dst[k] == nil then
			dst[k] = v
		end
	end
end

-- resolve the override policy for one walked file, given the dots.lua table
-- and the call-site default. file = { name, relpath, abspath, dest } (dest
-- as written, not expanded: the walk never contacts the target). Returns a
-- boolean.
local function resolve_override(entry_attrs, dots, file, call_default, dotspath)
	if entry_attrs and entry_attrs.override ~= nil then
		return entry_attrs.override == true
	end
	local pol = dots and dots["$override"]
	if pol ~= nil then
		if type(pol) == "boolean" then
			return pol
		end
		if type(pol) == "function" then
			local ok, r = pcall(pol, file)
			if not ok then
				error(("plan: $override in '%s' raised for '%s': %s"):format(dotspath, file.relpath, tostring(r)), 3)
			end
			return r == true
		end
		error(("plan: '$override' in '%s' must be a boolean or function(file) -> bool, got %s")
			:format(dotspath, type(pol)), 3)
	end
	return call_default == true
end

-- read a host-side symlink's target string (makac.fs has no readlink)
local function readlink(path)
	local res = makac.exec({ "readlink", "--", path })
	if res.code ~= 0 then
		return nil, (res.stderr or ""):gsub("%s+$", "")
	end
	return (res.stdout or ""):gsub("%s+$", "")
end

local function is_ignored(ignores, relpath)
	-- ignores: list of { base = <dots.lua dir rel, "" at root>, patterns = {...} }.
	-- Patterns from a directory's dots.lua are relative to THAT directory and
	-- apply to its whole subtree (that is the only reading under which a `**` pattern is
	-- meaningful; this is subtree REACH, not attribute inheritance).
	for _, ig in ipairs(ignores) do
		local sub
		if ig.base == "" then
			sub = relpath
		elseif relpath:sub(1, #ig.base) == ig.base and relpath:sub(#ig.base + 1, #ig.base + 1) == "/" then
			sub = relpath:sub(#ig.base + 2)
		end
		if sub then
			for _, pat in ipairs(ig.patterns) do
				if glob.match(pat, sub) then
					return true
				end
			end
		end
	end
	return false
end

-- walk dir (absolute), producing entries for everything under it.
-- rel = dir's path relative to the tree root ("" at the top).
local function walk_dir(dir, rel, ignores, opts, entries)
	local dots = M.load_dotsfile(dir)
	local dotspath = dir .. "/dots.lua"

	if dots ~= nil then
		local def = dots["$default_attrs"]
		if def ~= nil then
			if type(def) ~= "table" then
				error(("plan: '$default_attrs' in '%s' must be a table of attributes"):format(dotspath))
			end
			if def.absent ~= nil or def.skip ~= nil then
				error(("plan: '$default_attrs' in '%s' carries attributes only; 'absent'/'skip' are never inherited"):format(dotspath))
			end
			if def.override ~= nil then
				error(("plan: '$default_attrs' in '%s' carries attributes only; override is a policy — use '$override'"):format(dotspath))
			end
		end
		local ign = dots["$ignore"]
		if ign ~= nil then
			if type(ign) ~= "table" then
				error(("plan: '$ignore' in '%s' must be a list of glob patterns"):format(dotspath))
			end
			ignores = { table.unpack(ignores) }
			ignores[#ignores + 1] = { base = rel, patterns = ign }
		end
	end

	local items, lerr = makac.fs.listdir(dir)
	if not items then
		error(("plan: cannot list '%s': %s"):format(dir, tostring(lerr)))
	end
	-- deterministic output: sort by name before walking
	table.sort(items, function(a, b) return a.name < b.name end)

	for _, item in ipairs(items) do
		local name = item.name
		if not AUTO_IGNORE[name] then
			local child_rel = rel == "" and name or (rel .. "/" .. name)
			local child_abs = dir .. "/" .. name
			if is_ignored(ignores, child_rel) then
				-- skipped: matching files are dropped, matching directories
				-- are not descended into
			else
				local st = makac.fs.stat(child_abs)
				if not st then
					error(("plan: cannot stat '%s'"):format(child_abs))
				end
				if st.type == "dir" then
					walk_dir(child_abs, child_rel, ignores, opts, entries)
				else
					entries[#entries + 1] = M.synthesize(child_rel, child_abs, name, dots, st, dir, opts)
				end
			end
		end
	end
end

-- build the entry for one walked source node (file, symlink, or other)
function M.synthesize(relpath, abspath, name, dots, st, dir, opts)
	local dotspath = dir .. "/dots.lua"
	local explicit = dots and dots[name]
	if explicit ~= nil and type(explicit) ~= "table" then
		error(("plan: entry '%s' in '%s' must be a table"):format(name, dotspath))
	end

	local entry = {}
	merge_attrs(entry, explicit, "entry '" .. name .. "'", dotspath)
	if dots and dots["$default_attrs"] and explicit == nil then
		merge_attrs(entry, dots["$default_attrs"], "$default_attrs", dotspath)
	end

	entry.dest = opts.dest .. "/" .. relpath
	entry.override = resolve_override(explicit, dots, {
		name = name, relpath = relpath, abspath = abspath, dest = entry.dest,
	}, opts.call_override, dotspath)

	if st.type == "link" then
		if entry.link ~= nil then
			-- explicit link entry in dots.lua: the source node's bytes are
			-- irrelevant, ship the symlink as written
		elseif entry.reproduce == true then
			-- recreate the source symlink at dest as-is
			local target, terr = readlink(abspath)
			if not target then
				error(("plan: reproduce: cannot readlink '%s': %s"):format(abspath, tostring(terr)))
			end
			entry.src = nil
			entry.content = nil
			entry.link = target
		else
			-- default: dereference. A broken link is a walk error, loudly.
			if not makac.fs.read_file(abspath) then
				error(("plan: '%s' is a broken symlink (dereference mode); "
					.. "set reproduce = true to ship it as a symlink"):format(abspath))
			end
			entry.src = relpath
		end
	elseif st.type == "file" then
		if entry.link == nil then
			entry.src = relpath
		end
	else
		-- socket/fifo/other: nothing sensible to ship
		error(("plan: '%s' is a %s; only files, directories and symlinks can be walked")
			:format(abspath, st.type))
	end
	return entry
end

--- dots.tree(root, opts) — walk a source tree into an ordered entry list.
--- opts.dest: destination prefix (default "~"); opts.override: call-site
--- override default (default false). Returns a plain list of entry tables
--- whose order is deterministic (paths sorted). Raises on walk errors
--- (broken dots.lua, broken symlink, ...), never silently skips.
function M.tree(root, opts)
	opts = opts or {}
	local dest = opts.dest or "~"
	-- normalize: no trailing slash on dest so "dest .. '/' .. relpath" is clean
	dest = dest:gsub("/+$", "")
	if dest == "" then
		error("plan: dest must not be empty")
	end
	if type(root) ~= "string" or root == "" then
		error("plan: root is required and must be a non-empty string")
	end
	root = root:gsub("/+$", "")
	local entries = {}
	walk_dir(root, "", {}, {
		dest = dest,
		call_override = opts.override == true,
	}, entries)
	return entries
end

return M
