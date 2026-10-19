-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- dots:dir — ensure a managed DIRECTORY exists with the desired mode/owner.
-- Companion primitive to dots:file/dots:link, driven by the walk's ["."]
-- directory entries (lib/plan.lua). Pure: it never records snapshot entries
-- (dots:apply owns snapshot recording); a successful step reports out.mode /
-- out.owner so apply's record path can snapshot kind="dir" (no body).
--
-- Scope (directories are not files):
-- - the only managed fact is EXISTENCE plus mode/owner — never content.
-- - refusing to replace a non-dir node is louder than any conflict policy:
--   an existing file/symlink/other at dest is an error, unconditionally.
-- - there is no 'absent' for dirs (prune removes only EMPTY dirs, via rmdir).

local materialize = require("./materialize")

local M = {}

local function fail(msg)
	return { err = "dots:dir: " .. msg }
end

-- same refusal as dots:file/dots:link: .makac/dots/ is makac's own on-target
-- state (the snapshot store)
local function under_dotmakac(dest)
	return dest:find("/.makac/dots/", 1, true) ~= nil
		or dest:match("/%.makac/dots$") ~= nil
		or dest:match("^%.makac/dots/") ~= nil
		or dest == ".makac/dots"
end

local function resolve_target(with)
	if with.target == nil then
		return makac.host
	end
	local ok, t = pcall(makac.resolve_target, with)
	if not ok then return nil, tostring(t) end
	return t
end

--- Ensure the directory at with.dest exists with the requested attrs.
--- The field contract ('with' table) is documented in README.md.
function M.dir(with)
	if type(with) ~= "table" then
		return fail("'with' must be a table")
	end
	if type(with.dest) ~= "string" or with.dest == "" then
		return fail("'dest' is required and must be a non-empty string")
	end
	if under_dotmakac(with.dest) then
		return fail(("dest '%s' is under .makac/dots/ (makac's own on-target state); refusing"):format(with.dest))
	end
	if with.link ~= nil or with.content ~= nil or with.src ~= nil
		or with.renderer ~= nil or with.absent ~= nil then
		return fail("a directory entry carries ONLY dest/mode/owner/skip "
			.. "(content/src/link/renderer/absent belong to dots:file/dots:link)")
	end
	if with.skip then
		return { skipped = true }
	end
	local check = with.check == true
	-- THE ACK GATE: a walked root ["."] entry wants attrs on the DEST PREFIX
	-- ITSELF (usually "~" — the user's whole home). That is a real footgun,
	-- so apply must acknowledge it explicitly with manage_dest_dir = true.
	-- Bare dots:dir calls never set is_root_dir: an explicit dest IS the
	-- acknowledgment. Check mode reports through the gate (it shows what
	-- WOULD happen once flagged); the walk emits the entry unconditionally.
	if with.is_root_dir == true and with.manage_dest_dir ~= true and not check then
		return fail(("entry wants mode/owner on the DEST prefix itself ('%s'); "
			.. "refused without manage_dest_dir = true on dots:apply")
			:format(with.dest))
	end

	local target, terr = resolve_target(with)
	if not target then return fail(tostring(terr)) end
	local path, perr = materialize.resolve(target, with.dest)
	if not path then return fail(tostring(perr)) end

	local kind, kerr = materialize.remote_kind(target, path)
	if not kind then return fail(tostring(kerr)) end
	if kind ~= "absent" and kind ~= "dir" then
		return fail(("'%s' exists and is a %s; refusing to replace it with a directory")
			:format(path, kind))
	end

	-- managed ancestors arrive as their own walk entries and are already
	-- applied (dir entries precede their children); mkdir_parents covers any
	-- unmanaged gap. mkdir -p creates the leaf itself when given "path/.".
	local made = kind == "absent"
	if made and not check then
		local mok, merr = materialize.mkdir_parents(target, path .. "/.")
		if not mok then return fail(tostring(merr)) end
	end

	-- mode/owner: on creation they are always applied when specified (the
	-- mkdir result is umask-dependent); on an existing dir, only on drift.
	-- (After-write reapply mirrors dots:file's contract.)
	local changed = made
	if with.mode ~= nil then
		local need = true
		if not made then
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
		if not made then
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

	-- out carries mode/owner so apply's record path can snapshot kind="dir"
	-- with no body (dirs carry no bytes).
	return { changed = changed, out = { path = path, mode = with.mode, owner = with.owner } }
end

return M
