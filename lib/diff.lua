-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- diff engine for dots:diff — report drift between the plan and the
-- destination WITHOUT writing anything. One side is always the desired
-- bytes (post-render, computed host-side), the other is fetched from the
-- target. Unified diffs for content drift; a one-line record for mode
-- drift (a content diff cannot express modes, and drift where bytes are
-- equal would otherwise be invisible).

local materialize = require("./materialize")

local M = {}

local function tmp_with(bytes)
	local p = tostring(makac.fs.mktemp_file("dots-diff-"))
	makac.fs.write_file(p, bytes)
	return p
end

local function rm(p) pcall(makac.exec, { "rm", "-f", p }) end

--- unified diff of two LOCAL files; nil when identical. Labels are
--- a/<dest> / b/<dest> so the stream is patch(1)-readable.
local function unified(dest, old_path, new_path)
	local r = makac.exec({ "diff", "-u",
		"--label", "a/" .. dest, "--label", "b/" .. dest, old_path, new_path })
	if r.code == 0 then return nil end
	if r.code ~= 1 then return nil, "diff failed: " .. (r.stderr or "") end
	return r.stdout
end

-- --- per-entry reporting ----------------------------------------------------
--
-- check_entry returns an item table:
--   { dest = <as written>, path = <resolved>,
--     content = <unified diff text or a one-line note> | nil,
--     mode    = { have = "777", want = "0600" } | nil,
--     err     = <target/recipe failure instead of a report> | nil,
--     skipped = true | nil }
-- 'converged' entries return an item with all of content/mode/err nil.

--- Report one entry against the target. Never writes to the target.
function M.check_entry(entry, root, target)
	if entry.skip then return { dest = entry.dest, skipped = true } end
	local item = { dest = entry.dest }
	local path, perr = materialize.resolve(target, entry.dest)
	if not path then
		item.err = tostring(perr)
		return item
	end
	item.path = path

	local kind, kerr = materialize.remote_kind(target, path)
	if not kind then
		item.err = tostring(kerr)
		return item
	end

	-- absent entries (either verb): report removal of any non-dir node
	-- (directories are never removed, by the actions' contract)
	if entry.absent then
		if kind == "file" then
			local cur, cerr = materialize.fetch_bytes(target, path)
			if not cur then
				item.err = tostring(cerr)
				return item
			end
			local p = tmp_with(cur)
			item.content = unified(entry.dest, p, "/dev/null") or ("removed: " .. path)
			rm(p)
		elseif kind == "link" or kind == "other" then
			item.content = ("removed: %s (%s)"):format(path, kind)
		end
		return item
	end

	-- symlink entries
	if entry.link ~= nil then
		if kind == "absent" then
			item.content = ("new: symlink -> %s"):format(entry.link)
		elseif kind ~= "link" then
			item.content = ("%s exists as a %s, entry wants a symlink to '%s'")
				:format(path, kind, entry.link)
		else
			local cur = materialize.readlink(target, path)
			if cur ~= entry.link then
				item.content = ("symlink target: '%s' -> '%s'"):format(tostring(cur), entry.link)
			end
		end
		return item
	end

	-- directory entries: drift on EXISTENCE + mode/owner only, never content
	-- (a directory has no bytes to diff)
	if entry.dir == true then
		if kind == "absent" then
			item.content = ("new: directory %s"):format(path)
			return item
		end
		if kind ~= "dir" then
			item.content = ("%s exists as a %s, entry wants a directory"):format(path, kind)
			return item
		end
		if entry.mode ~= nil then
			local have = materialize.remote_mode(target, path)
			if have and not materialize.mode_eq(have, entry.mode) then
				item.mode = { have = have, want = entry.mode }
			end
		end
		if entry.owner ~= nil then
			local have = materialize.remote_owner(target, path)
			if have and not materialize.owner_eq(have, entry.owner) then
				item.owner = { have = have, want = entry.owner }
			end
		end
		return item
	end

	-- materialize entries
	local desired, derr = materialize.desired_bytes(entry, root)
	if not desired then
		item.err = tostring(derr)
		return item
	end
	if kind == "absent" then
		local p = tmp_with(desired)
		item.content = unified(entry.dest, "/dev/null", p)
		rm(p)
	elseif kind == "file" then
		local cur, cerr = materialize.fetch_bytes(target, path)
		if not cur then
			item.err = tostring(cerr)
			return item
		end
		if cur ~= desired then
			local oldp, newp = tmp_with(cur), tmp_with(desired)
			item.content = unified(entry.dest, oldp, newp)
			rm(oldp); rm(newp)
		end
		-- mode drift is orthogonal to content (bytes may be equal)
		if entry.mode ~= nil then
			local have = materialize.remote_mode(target, path)
			if have and not materialize.mode_eq(have, entry.mode) then
				item.mode = { have = have, want = entry.mode }
			end
		end
	else
		item.content = ("%s exists as a %s, entry wants a file"):format(path, kind)
	end
	return item
end

--- Report every entry (walk order preserved). Returns
---   { items = { <check_entry item>, ... } }
function M.report(entries, root, target)
	local items = {}
	for _, e in ipairs(entries) do
		items[#items + 1] = M.check_entry(e, root, target)
	end
	return { items = items }
end

--- Render items as the two-section human report (content diffs first, then
--- mode-drift lines). Returns "" when nothing drifted.
function M.render(items)
	local contents, modes = {}, {}
	for _, it in ipairs(items) do
		if it.content then contents[#contents + 1] = it.content end
		if it.mode then
			modes[#modes + 1] = ("MODE %s: %s -> %s"):format(it.dest, it.mode.have, it.mode.want)
		end
		if it.owner then
			modes[#modes + 1] = ("OWNER %s: %s -> %s"):format(it.dest, it.owner.have, it.owner.want)
		end
	end
	local out = {}
	if #contents > 0 then
		out[#out + 1] = "## contents"
		for _, c in ipairs(contents) do out[#out + 1] = c end
	end
	if #modes > 0 then
		out[#out + 1] = "## modes"
		for _, m in ipairs(modes) do out[#out + 1] = m end
	end
	return table.concat(out, "\n")
end

return M
