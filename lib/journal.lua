-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- lib/journal.lua — the managed journal (design/main.md §Managed journal):
-- the record of paths this package has written, kept under
--   <data_dir>/dots/<target name>/managed
-- — the basis for a future prune/unapply.
--
-- Format: newline-separated absolute (expanded) dest paths. The file is
-- deduped and sorted, rewritten wholesale on every update (these files are
-- small); writes are atomic. The journal also records REMOVE operations —
-- an `absent = true` cleanup is still "a path this package has written".
--
-- Host-side I/O only: the journal lives in the project's .makac data dir
-- (makac.data_dir), next to makac's own targets state.

local M = {}

--- Path of the journal file for one target.
function M.file_path(datadir, target_name)
	return datadir .. "/dots/" .. target_name .. "/managed"
end

--- Current journal contents as a sorted array of paths ({} when absent).
function M.list(datadir, target_name)
	local body = makac.fs.read_file(M.file_path(datadir, target_name))
	if body == nil then return {} end
	local out = {}
	for line in body:gmatch("[^\n]+") do
		out[#out + 1] = line
	end
	table.sort(out)
	return out
end

--- Record paths: union with the existing journal, dedupe, sort, rewrite
--- wholesale. paths must be absolute (already expanded by the caller).
function M.update(datadir, target_name, paths)
	assert(type(datadir) == "string" and datadir ~= "",
		"journal.update: datadir must be a non-empty string")
	assert(type(target_name) == "string" and target_name ~= "",
		"journal.update: target_name must be a non-empty string")
	assert(type(paths) == "table", "journal.update: paths must be a table")
	local set = {}
	for _, p in ipairs(M.list(datadir, target_name)) do set[p] = true end
	for _, p in ipairs(paths) do
		assert(type(p) == "string" and p:sub(1, 1) == "/",
			("journal.update: paths must be absolute, got %s"):format(tostring(p)))
		set[p] = true
	end
	local all = {}
	for p in pairs(set) do all[#all + 1] = p end
	table.sort(all)
	local file = M.file_path(datadir, target_name)
	makac.fs.mkdir_p((file:gsub("/[^/]*$", "")))
	makac.fs.write_file(file, (#all > 0) and (table.concat(all, "\n") .. "\n") or "",
		{ atomic = true })
	return all
end

return M
