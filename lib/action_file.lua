-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:file — the primitive action. One effect: ensure the node at dest
-- matches the entry.
-- Target-agnostic via lib/materialize.lua; per-file failures set `err`
-- (dots:apply turns them into data).
--
-- dots:file / dots:link are PURE primitives: they never record snapshot
-- entries themselves (dots:apply owns snapshot recording). To spare apply a
-- re-render, a successful content write reports the deployed bytes in
-- out.deployed_bytes (for links: the stored target string).

local materialize = require("./materialize")

local M = {}

-- Refuse dests inside the store directory: .makac/dots/ is makac's own
-- on-target state (the snapshot); the plan walk auto-ignores it, but the
-- files= escape hatch and bare dests bypass the walk.
local function under_dotmakac(dest)
	return dest:find("/.makac/dots/", 1, true) ~= nil
		or dest:match("/%.makac/dots$") ~= nil
		or dest:match("^%.makac/dots/") ~= nil
		or dest == ".makac/dots"
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

--- Ensure the node at with.dest matches the entry. The field contract
--- ('with' table) is documented in README.md.
function M.file(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end
	if type(with.dest) ~= "string" or with.dest == "" then
		return fail("'dest' is required and must be a non-empty string")
	end
	if under_dotmakac(with.dest) then
		return fail(("dest '%s' is under .makac/dots/ (makac's own on-target state); refusing"):format(with.dest))
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
	local path, perr = materialize.resolve(target, with.dest)
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
	end

	-- mode / owner: after a write they are always applied when specified (the
	-- temp-then-move write lands 0600); on a no-write
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
			end
		end
	end

	local out = { path = path, sha256 = dsha }
	if wrote and not check then
		-- the deployed bytes, so dots:apply can record the snapshot entry
		-- without re-rendering
		out.deployed_bytes = bytes
		out.deployed_sha256 = dsha
	end
	return { changed = changed, out = out }
end

--- dots:link — opt-in stow-style symlink entries. with.link is the
--- string to store in the symlink, relative or absolute, verbatim.
function M.link(with)
	if type(with) ~= "table" then
		return lfail("'with' must be a table")
	end
	if type(with.dest) ~= "string" or with.dest == "" then
		return lfail("'dest' is required and must be a non-empty string")
	end
	if under_dotmakac(with.dest) then
		return lfail(("dest '%s' is under .makac/dots/ (makac's own on-target state); refusing"):format(with.dest))
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
	local path, perr = materialize.resolve(target, with.dest)
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
		return { changed = true,
			out = { path = path, deployed_bytes = with.link, deployed_sha256 = makac.sha256(with.link) } }
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
		return { changed = true,
			out = { path = path, deployed_bytes = with.link, deployed_sha256 = makac.sha256(with.link) } }
	end

	-- file / dir / other: a real node at dest is never replaced by a symlink
	return lfail(("conflict: '%s' exists as a %s; refusing to replace it with a symlink")
		:format(path, kind))
end

return M
