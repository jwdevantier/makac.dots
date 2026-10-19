-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- lib/snapshot.lua — the on-target snapshot store: a record of what was
-- last deployed, kept ON the target under
--
--   <dest_root>/.makac/dots/snapshot/
--
-- where dest_root is the apply `dest` prefix (usually "~"). State lives on
-- the target next to the files it describes, so host reinstalls never lose
-- track of a deployment.
--
-- Layout: FLAT — one entry per managed path, the entry filename being the
-- lowercase hex sha256 of the path's relpath relative to dest_root (orphan
-- detection is then a single readdir, no tree walk on the target).
--
-- Entry format (v1), three parts:
--   line 1:  magic "--- makac.dots,1" — strict grammar ^%-%-%- ([%w.]+),(%d+)$.
--            Readers reject anything else, and reject a NEWER version,
--            loudly.
--   line 2:  one line of compact JSON: file (relpath, observability only —
--            the filename is its hash), tree (owner id), kind
--            ("file"|"link"|"dir"), mode, owner (both omitted when not
--            carried), sha256 (of the body bytes).
--   line 3+: the deployed bytes VERBATIM (raw, binary-safe). Link entries:
--            the stored target string. Dir entries: no body (sha256 of "").
--
-- No graveyard: removals and prune DROP entries — the snapshot never holds
-- bytes whose target counterpart is deliberately gone (snapshot bytes ==
-- target bytes at every instant; secrets decay with the target tree).
--
-- ALL target-side IO goes through lib/materialize.lua — host code here only
-- assembles/parses entry byte strings; makac.fs never touches a target path.

local materialize = require("./materialize")

local M = {}

local VERSION = 1
local MAGIC = "--- makac.dots," .. VERSION

--- Lowercase hex sha256 of a relpath — the entry's filename in the store.
--- The relpath is hashed verbatim (no normalization): callers pass it
--- relative to dest_root, e.g. ".config/foo/config".
function M.hash(relpath)
	return makac.sha256(relpath)
end

--- Pure path join: the snapshot directory for a dest_root (NOT resolved —
--- "~" stays "~"; internal functions resolve first, callers needing a
--- target path must too).
function M.dir(dest_root)
	if #dest_root > 1 then
		dest_root = dest_root:gsub("/+$", "")
	end
	return dest_root .. "/.makac/dots/snapshot"
end

-- Parse raw entry bytes into { meta = {...}, body = "..." }.
-- Returns (nil, err) on ANY deviation: the store is authoritative, so a
-- malformed entry must be loud, never silently skipped.
local function parse_entry(raw)
	local eol1 = raw:find("\n", 1, true)
	if not eol1 then
		return nil, "snapshot entry truncated (no magic line)"
	end
	local line1 = raw:sub(1, eol1 - 1)
	local product, ver = line1:match("^%-%-%- ([%w.]+),(%d+)$")
	if not product then
		return nil, ("malformed magic line %q (want e.g. %q)"):format(line1, MAGIC)
	end
	if product ~= "makac.dots" then
		return nil, ("not a makac.dots snapshot entry (product %q)"):format(product)
	end
	if tonumber(ver) > VERSION then
		return nil, ("snapshot entry version %d is newer than supported version %d")
			:format(tonumber(ver), VERSION)
	end
	local eol2 = raw:find("\n", eol1 + 1, true)
	if not eol2 then
		return nil, "snapshot entry truncated (no metadata line)"
	end
	local jok, meta = pcall(makac.json.loads, raw:sub(eol1 + 1, eol2 - 1))
	if not jok or type(meta) ~= "table" then
		return nil, "malformed metadata line: " .. tostring(meta)
	end
	if type(meta.file) ~= "string" or meta.file == "" then
		return nil, "metadata lacks 'file'"
	end
	if type(meta.tree) ~= "string" or meta.tree == "" then
		return nil, "metadata lacks 'tree'"
	end
	if meta.kind ~= "file" and meta.kind ~= "link" and meta.kind ~= "dir" then
		return nil, "metadata has bad 'kind': " .. tostring(meta.kind)
	end
	if type(meta.sha256) ~= "string" or not meta.sha256:match("^%x%x+$") then
		return nil, "metadata lacks a hex 'sha256'"
	end
	if meta.mode ~= nil and type(meta.mode) ~= "string" then
		return nil, "metadata 'mode' must be a string"
	end
	if meta.owner ~= nil and type(meta.owner) ~= "string" then
		return nil, "metadata 'owner' must be a string"
	end
	return { meta = meta, body = raw:sub(eol2 + 1) }
end

--- Write (or replace) the entry for relpath. meta = { tree=, kind=, mode=,
--- owner= } (tree/kind required; mode/owner omitted when the entry does not
--- carry them); bytes is the body string ("" for dirs, the stored target
--- string for links). file/sha256 are derived. Tolerates dest_root not
--- existing (mkdir -p's the snapshot dir; the .makac chain is chmod 0700 —
--- the store may hold secrets). Entries land 0600 via
--- materialize.write_file. Atomic (temp-then-move).
function M.write(target, dest_root, relpath, meta, bytes)
	if type(relpath) ~= "string" or relpath == "" or relpath:sub(1, 1) == "/" then
		return nil, "snapshot.write: relpath must be a non-empty relative path"
	end
	if type(bytes) ~= "string" then
		return nil, "snapshot.write: bytes must be a string"
	end
	if type(meta) ~= "table" or type(meta.tree) ~= "string" or meta.tree == "" then
		return nil, "snapshot.write: meta.tree must be a non-empty string"
	end
	if meta.kind ~= "file" and meta.kind ~= "link" and meta.kind ~= "dir" then
		return nil, "snapshot.write: meta.kind must be 'file', 'link', or 'dir'"
	end
	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end
	local snapdir = M.dir(root)
	local entry_path = snapdir .. "/" .. M.hash(relpath)
	local header = {
		file = relpath,
		tree = meta.tree,
		kind = meta.kind,
		sha256 = makac.sha256(bytes),
	}
	if meta.mode ~= nil then header.mode = meta.mode end
	if meta.owner ~= nil then header.owner = meta.owner end
	local jok, json = pcall(makac.json.dumps, header)
	if not jok then
		return nil, "snapshot.write: cannot encode metadata: " .. tostring(json)
	end
	-- mkdir -p the snapshot dir itself (parent of the entry file); mkdir -p
	-- honors umask, so chmod the whole .makac chain to 0700 explicitly.
	local ok, err = materialize.mkdir_parents(target, entry_path)
	if not ok then return nil, err end
	local base = root
	if #base > 1 then base = (base:gsub("/+$", "")) end
	for _, d in ipairs({
		base .. "/.makac",
		base .. "/.makac/dots",
		snapdir,
	}) do
		local cok, cerr = materialize.apply_mode(target, d, "0700")
		if not cok then return nil, cerr end
	end
	local wok, werr = materialize.write_file(target, entry_path, MAGIC .. "\n" .. json .. "\n" .. bytes)
	if not wok then return nil, werr end
	return true
end

--- Read the entry for relpath: { meta = {...}, body = "..." }.
--- Returns (nil) with NO error when the entry simply does not exist —
--- absence is a normal state (2-way fallback); (nil, err) means a corrupt
--- entry or an IO failure.
function M.read(target, dest_root, relpath)
	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end
	local entry_path = M.dir(root) .. "/" .. M.hash(relpath)
	local kind, kerr = materialize.remote_kind(target, entry_path)
	if not kind then return nil, kerr end
	if kind == "absent" then return nil end
	if kind ~= "file" then
		return nil, "snapshot entry '" .. entry_path .. "' is a " .. kind .. ", not a file"
	end
	local raw, ferr = materialize.fetch_bytes(target, entry_path)
	if not raw then return nil, ferr end
	local entry, perr = parse_entry(raw)
	if not entry then
		return nil, ("snapshot entry for %q: %s"):format(relpath, perr)
	end
	if entry.meta.file ~= relpath then
		return nil, ("snapshot entry for %q names a different file %q (store corrupt)")
			:format(relpath, entry.meta.file)
	end
	return entry
end

--- List all entries: { { relpath=..., meta={...} }, ... } sorted by
--- relpath; {} when the snapshot dir does not exist. Bodies are NOT
--- returned (headers only). A single malformed entry fails the whole list
--- loudly — prune runs on top of this and must never guess.
function M.list(target, dest_root)
	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end
	local snapdir = M.dir(root)
	local names, nerr = materialize.readdir(target, snapdir)
	if not names then return nil, nerr end
	local out = {}
	for _, name in ipairs(names) do
		local kind, kerr = materialize.remote_kind(target, snapdir .. "/" .. name)
		if not kind then return nil, kerr end
		if kind ~= "file" then
			return nil, ("snapshot store: %q is a %s, not an entry file"):format(name, kind)
		end
		local raw, ferr = materialize.fetch_bytes(target, snapdir .. "/" .. name)
		if not raw then return nil, ferr end
		local entry, perr = parse_entry(raw)
		if not entry then
			return nil, ("snapshot store entry %q: %s"):format(name, perr)
		end
		out[#out + 1] = { relpath = entry.meta.file, meta = entry.meta }
	end
	table.sort(out, function(a, b) return a.relpath < b.relpath end)
	return out
end

--- Drop the entries for a list of relpaths (removals and prune forget
--- go through here — there is deliberately no way to keep body bytes for
--- a target path that is gone).
function M.remove(target, dest_root, relpaths)
	local root, rerr = materialize.resolve(target, dest_root)
	if not root then return nil, rerr end
	local snapdir = M.dir(root)
	for _, relpath in ipairs(relpaths) do
		local ok, err = materialize.remove_path(target, snapdir .. "/" .. M.hash(relpath))
		if not ok then
			return nil, ("dropping snapshot entry for %q failed: %s"):format(relpath, err)
		end
	end
	return true
end

return M
