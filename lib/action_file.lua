-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:file — the primitive action (design/main.md §The primitive action:
-- "dots:file"). One effect: ensure the node at dest matches the entry.
-- Target-agnostic via lib/materialize.lua; per-file failures set `err`
-- (dots:apply turns them into data).

local materialize = require("./materialize")
local journal = require("./journal")

local M = {}

--- Record a path in the managed journal (design §Managed journal) after a
--- successful mutation. Called on write / remove / chmod / chown / symlink
--- sites (all already guarded against check mode). NEVER fails the step: a
--- lost journal line is recoverable, a hard error would break applies for no
--- benefit. No-ops when there is no data dir (makac.data_dir unset).
local function record(target, path)
	local dd = makac.data_dir
	if dd == nil then return end
	pcall(journal.update, dd, tostring(target.name or "unknown"), { path })
end

local function fail(msg)
	return { err = "dots:file: " .. msg }
end

local function lfail(msg)
	return { err = "dots:link: " .. msg }
end

local function resolve_target(with)
	if with.target == nil then
		return makac.host
	end
	local ok, t = pcall(makac.resolve_target, with)
	if not ok then return nil, tostring(t) end
	return t
end

--- Ensure the node at with.dest matches the entry. See design §Entry schema
--- for the field contract.
function M.file(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end
	if type(with.dest) ~= "string" or with.dest == "" then
		return fail("'dest' is required and must be a non-empty string")
	end
	if with.skip then
		return { skipped = true }
	end
	if with.link ~= nil then
		return fail("a 'link' entry is a symlink; use dots:link for it")
	end
	if with.content ~= nil and with.src ~= nil then
		return fail("give 'content' or 'src', not both")
	end
	if not with.absent and with.content == nil and with.src == nil then
		return fail("an entry needs one of src / content / absent / skip")
	end

	local target, terr = resolve_target(with)
	if not target then return fail(terr) end
	local path, perr = materialize.expand(target, with.dest)
	if not path then return fail(tostring(perr)) end
	local check = with.check == true

	if with.absent then
		local kind, kerr = materialize.remote_kind(target, path)
		if not kind then return fail(tostring(kerr)) end
		if kind == "absent" then
			return { changed = false, out = { path = path } }
		end
		if kind == "dir" then
			return fail(("'%s' is a directory; 'absent' entries never remove directories"):format(path))
		end
		if check then
			return { changed = true, out = { path = path } }
		end
		local rok, rerr = materialize.remove_path(target, path)
		if not rok then return fail(tostring(rerr)) end
		record(target, path)
		return { changed = true, out = { path = path } }
	end

	-- materialize: content / src (+ optional renderer)
	local bytes, berr = materialize.desired_bytes(with, with.root)
	if not bytes then return fail(tostring(berr)) end
	local dsha = makac.sha256(bytes)

	local kind, kerr = materialize.remote_kind(target, path)
	if not kind then return fail(tostring(kerr)) end
	if kind == "dir" then
		return fail(("'%s' exists and is a directory; refusing to replace it with a file"):format(path))
	end

	local override = with.override == true
	local wrote = false

	if kind == "absent" then
		wrote = true
	else
		-- file / link / other: compare desired bytes against reality
		local same = false
		if kind == "file" then
			local asha, aerr = materialize.remote_sha256(target, path)
			if not asha then return fail(tostring(aerr)) end
			same = (asha == dsha)
		end
		-- a link/other kind never "matches" a materialized file: it differs
		if not same then
			if not override then
				return fail(("conflict: '%s' exists and differs and override = false; leaving it untouched")
					:format(path))
			end
			wrote = true
		end
	end

	if wrote and not check then
		local mok, merr = materialize.mkdir_parents(target, path)
		if not mok then return fail(tostring(merr)) end
		local wok, werr = materialize.write_file(target, path, bytes)
		if not wok then return fail(tostring(werr)) end
		record(target, path)
	end

	-- mode / owner: after a write they are always applied when specified (the
	-- temp-then-move write lands 0600, design §Entry schema); on a no-write
	-- they are applied only on drift.
	local changed = wrote
	if with.mode ~= nil then
		local need = true
		if not wrote then
			local rm, rerr = materialize.remote_mode(target, path)
			if not rm then return fail(tostring(rerr)) end
			need = not materialize.mode_eq(rm, with.mode)
		end
		if need then
			changed = true
			if not check then
				local aok, aerr = materialize.apply_mode(target, path, with.mode)
				if not aok then return fail(tostring(aerr)) end
				record(target, path)
			end
		end
	end
	if with.owner ~= nil then
		local need = true
		if not wrote then
			local ro, rerr = materialize.remote_owner(target, path)
			if not ro then return fail(tostring(rerr)) end
			need = not materialize.owner_eq(ro, with.owner)
		end
		if need then
			changed = true
			if not check then
				local aok, aerr = materialize.apply_owner(target, path, with.owner)
				if not aok then return fail(tostring(aerr)) end
				record(target, path)
			end
		end
	end

	return { changed = changed, out = { path = path, sha256 = dsha } }
end

--- dots:link — opt-in stow-style symlink entries (design §The model: "Link
--- is an opt-in verb... It cannot carry mode/owner."). with.link is the
--- string to store in the symlink, relative or absolute, verbatim.
function M.link(with)
	if type(with) ~= "table" then
		return lfail("'with' must be a table")
	end
	if type(with.dest) ~= "string" or with.dest == "" then
		return lfail("'dest' is required and must be a non-empty string")
	end
	if with.mode ~= nil or with.owner ~= nil then
		return lfail("a symlink cannot carry mode/owner")
	end
	if with.skip then
		return { skipped = true }
	end
	if with.content ~= nil or with.src ~= nil then
		return lfail("a link entry carries 'link', not 'content'/'src'; use dots:file for those")
	end
	if not with.absent and type(with.link) ~= "string" then
		return lfail("'link' is required (the string to store in the symlink)")
	end

	local target, terr = resolve_target(with)
	if not target then return lfail(terr) end
	local path, perr = materialize.expand(target, with.dest)
	if not path then return lfail(tostring(perr)) end
	local check = with.check == true

	local kind, kerr = materialize.remote_kind(target, path)
	if not kind then return lfail(tostring(kerr)) end

	if with.absent then
		-- remove the LINK (never follow it), and only the link: a regular
		-- file or directory at dest is not ours to remove.
		if kind == "absent" then
			return { changed = false, out = { path = path } }
		end
		if kind ~= "link" then
			return lfail(("absent: '%s' is a %s, not a symlink; refusing to remove it")
				:format(path, kind))
		end
		if check then
			return { changed = true, out = { path = path } }
		end
		local rok, rerr = materialize.remove_path(target, path)
		if not rok then return lfail(tostring(rerr)) end
		record(target, path)
		return { changed = true, out = { path = path } }
	end

	if kind == "absent" then
		if check then
			return { changed = true, out = { path = path } }
		end
		local mok, merr = materialize.mkdir_parents(target, path)
		if not mok then return lfail(tostring(merr)) end
		local sok, serr = materialize.symlink(target, path, with.link, false)
		if not sok then return lfail(tostring(serr)) end
		record(target, path)
		return { changed = true, out = { path = path } }
	end

	if kind == "link" then
		local cur, lerr = materialize.readlink(target, path)
		if not cur then return lfail(tostring(lerr)) end
		if cur == with.link then
			return { changed = false, out = { path = path } }
		end
		if with.override ~= true then
			return lfail(("conflict: '%s' is a symlink to '%s', not '%s', and override = false; leaving it untouched")
				:format(path, cur, with.link))
		end
		if check then
			return { changed = true, out = { path = path } }
		end
		local sok, serr = materialize.symlink(target, path, with.link, true)
		if not sok then return lfail(tostring(serr)) end
		record(target, path)
		return { changed = true, out = { path = path } }
	end

	-- file / dir / other: a real node at dest is never replaced by a symlink
	return lfail(("conflict: '%s' exists as a %s; refusing to replace it with a symlink")
		:format(path, kind))
end

return M
