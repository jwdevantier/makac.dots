-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- txtar: a Lua port of Go's txtar archive format (golang.org/x/tools/txtar),
-- for tests that need a small tree of files: one archive literal unpacks
-- into a temporary directory instead of N write_file calls.
--
-- Format:
--
--	Optional comment lines.
--	-- name1 --
--	data lines...
--	-- name2 --
--	data lines...
--
-- Everything before the first "-- name --" marker is the comment. A file's
-- data is the raw bytes between markers — the newline ending the last data
-- line is included, so a file has no trailing newline only when the archive
-- itself ends without one. The format has no escaping: no data line may
-- itself look like a marker (text files only).
--
-- Inline long strings may be indented to match the surrounding code; the
-- common leading-whitespace prefix is stripped before parsing, so the
-- indentation never leaks into file data (see dedent below).

local M = {}

-- Strip the common leading-whitespace prefix shared by all non-blank
-- lines. Flush-left input (e.g. archives read from disk) is returned
-- unchanged; indented inline literals come out as if written at column 0,
-- while any *deeper* indentation inside file data is preserved relative
-- to the base.
local function dedent(s)
	local indent
	for line in (s .. "\n"):gmatch("(.-)\n") do
		if line:find("%S") then
			local lead = line:match("^%s*")
			if indent == nil then
				indent = lead
			else
				local i = 0
				while i < #indent and i < #lead
					and indent:sub(i + 1, i + 1) == lead:sub(i + 1, i + 1)
				do
					i = i + 1
				end
				indent = indent:sub(1, i)
			end
		end
	end
	if indent == nil or indent == "" then return s end
	local out = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		if line:sub(1, #indent) == indent then
			out[#out + 1] = line:sub(#indent + 1)
		elseif line:find("%S") then
			out[#out + 1] = line -- cannot happen: indent is a common prefix
		else
			out[#out + 1] = "" -- whitespace-only line shorter than indent
		end
	end
	return table.concat(out, "\n")
end

-- marker name, or nil. Go strips the "-- " / " --" delimiters once, so
-- inner whitespace survives: "--  a  --" names the file " a " (which
-- unpack then rejects). A greedy middle matches Go's "trim prefix and
-- suffix exactly once" behavior for names like "a -- b".
local function marker_name(line)
	return line:match("^%-%- (.*) %-%-$")
end

--- Parse an archive string into
---   { comment = string, files = { { name = ..., data = ... }, ... } }
--- preserving file order. Parsing never fails; name validation happens in
--- unpack, where the names turn into paths.
function M.parse(archive)
	assert(type(archive) == "string", "txtar.parse: archive must be a string")
	archive = dedent(archive)
	local files = {}
	local comment = archive -- no markers at all: everything is comment
	local pos, n = 1, #archive
	local cur_name, cur_start
	while pos <= n do
		local nl = archive:find("\n", pos, true) or (n + 1)
		local line = archive:sub(pos, nl - 1)
		if line:sub(-1) == "\r" then line = line:sub(1, -2) end
		local name = marker_name(line)
		if name then
			if cur_name then
				-- data runs up to and including the newline that ends the
				-- line before this marker
				files[#files + 1] = { name = cur_name, data = archive:sub(cur_start, pos - 1) }
			else
				comment = archive:sub(1, pos - 1)
			end
			cur_name = name
			cur_start = nl + 1
		end
		pos = nl + 1
	end
	if cur_name then
		-- data to EOF; no trailing newline iff the archive lacks one
		files[#files + 1] = { name = cur_name, data = archive:sub(cur_start, n) }
	end
	return { comment = comment, files = files }
end

-- Normalize and validate a file name before it becomes a path under dir.
local function check_name(name)
	if name:match("^%s") or name:match("%s$") then
		error(("txtar.unpack: file name %q has leading/trailing whitespace"):format(name), 0)
	end
	if name == "" then
		error("txtar.unpack: empty file name", 0)
	end
	if name:sub(1, 1) == "/" then
		error(("txtar.unpack: absolute path %q not allowed"):format(name), 0)
	end
	for seg in (name .. "/"):gmatch("(.-)/") do
		if seg == "" then
			error(("txtar.unpack: bad path %q (empty component)"):format(name), 0)
		end
		if seg == "." or seg == ".." then
			error(("txtar.unpack: path %q escapes the target directory"):format(name), 0)
		end
	end
	return name
end

--- Unpack an archive (a string, or the result of parse) into dir,
--- creating it and any intermediate parents as needed. dir defaults to a
--- fresh makac.fs.mktemp_dir("dots-txtar-"). Returns dir.
function M.unpack(archive, dir)
	if type(archive) == "string" then
		archive = M.parse(archive)
	end
	dir = dir and tostring(dir) or tostring(makac.fs.mktemp_dir("dots-txtar-"))
	makac.fs.mkdir_p(dir)
	local seen = {}
	for _, f in ipairs(archive.files) do
		local rel = check_name(f.name)
		if seen[rel] then
			error(("txtar.unpack: duplicate entry %q"):format(rel), 0)
		end
		seen[rel] = true
		local path = dir .. "/" .. rel
		local parent = path:match("^(.+)/[^/]+$")
		if parent then makac.fs.mkdir_p(parent) end
		makac.fs.write_file(path, f.data)
	end
	return dir
end

return M
