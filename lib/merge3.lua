-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- lib/merge3.lua — RUNNER-side 3-way merge machinery for integration
-- frontends, on top of the deployed snapshot (the merge base). Mechanism
-- only: it never prompts and never writes anywhere. The host-side frontend
-- (e.g. makac.mydots) drives $EDITOR over the conflict-marked result.
--
-- Everything runs host-side: callers pass base/target/source as Lua STRINGS
-- (already fetched/rendered), they land in temp files, and `diff3 -m` (GNU
-- diffutils, POSIX-family, a new RUNNER-side dependency — only integration
-- workflows need it) produces the merged output with LABELED conflict
-- markers (RCS/diff3 convention, popularized by git — editors highlight it
-- natively). The labels are mandatory and fixed:
--
--     <<<<<<< Untracked Changes      (= edits on the target)
--     ||||||| Old                    (= last deployed — the merge base)
--     =======
--     >>>>>>> New                    (= new source from the tree)
--
-- The user must never have to remember which arrow is which, and the
-- frontend prints a legend before opening the editor.
--
-- Exact bytes are preserved: a missing trailing newline ("No newline at
-- end of file") survives clean-merged round trips, because diff3 is fed the
-- byte strings verbatim. (Conflict regions AT the file end when inputs lack
-- a trailing newline come back with diff3's gluing quirks — the user edits
-- such a region by hand anyway, so this is a reporting concern only.)

local M = {}

-- the fixed conflict-marker labels (exported: the frontend prints them in
-- its legend so the user sees exactly what the editor will show)
M.TARGET_LABEL = "Untracked Changes" -- edits on the target
M.BASE_LABEL = "Old" -- last deployed (the merge base)
M.SOURCE_LABEL = "New" -- new source from the tree

-- ---- marker grammar --------------------------------------------------------

-- A marker line is exactly seven identical marker chars at LINE START.
-- '<' / '|' / '>' tolerate a label after the seven chars (ANY label, not
-- just ours); '=' is emitted by diff3 as exactly seven '=' alone on the
-- line. Returns "<"/"|"/"="/">" or nil.
local function marker_line(line)
	if line:match("^<<<<<<<") then return "<" end
	if line:match("^%|%|%|%|%|%|%|") then return "|" end
	if line:match("^=======$") then return "=" end
	if line:match("^>>>>>>>") then return ">" end
	return nil
end

-- iterate lines of text with their 1-based line numbers; a text ending in
-- "\n" has NO trailing empty line ("a\n" → one line). Bytes are preserved;
-- only the line framing is split off.
local function lines_of(text)
	local lines = {}
	local pos = 1
	while pos <= #text do
		local nl = text:find("\n", pos, true)
		if nl == nil then
			lines[#lines + 1] = text:sub(pos)
			break
		end
		lines[#lines + 1] = text:sub(pos, nl - 1)
		pos = nl + 1
	end
	return lines
end

-- ---- temp-file plumbing ----------------------------------------------------

local function tmp_with(bytes)
	local p = tostring(makac.fs.mktemp_file("dots-merge3-"))
	local ok, err = pcall(makac.fs.write_file, p, bytes)
	if not ok or err == false then
		return nil, "merge3: cannot stage temp file: " .. tostring(err)
	end
	return p
end

local function rm(p)
	pcall(makac.exec, { "rm", "-f", "--", p })
end

local function have_diff3()
	local ok, res = pcall(makac.exec, { "sh", "-c", "command -v diff3" })
	return ok and res.code == 0
end

-- NUL bytes mean binary content: diff3's output would be garbage and a
-- text-merge UX would corrupt the file — refuse loudly instead.
local function binary_refusal(base, target, source)
	if (base or ""):find("\0", 1, true) then return "base" end
	if (target or ""):find("\0", 1, true) then return "target" end
	if (source or ""):find("\0", 1, true) then return "source" end
	return nil
end

--- 3-way merge. base = deployed bytes (snapshot = merge base), target = the
--- target's current bytes, source = rendered source bytes. All three are
--- plain Lua strings. Returns:
---   { clean = true,  result   = <merged string> }               -- disjoint edits
---   { clean = false, marked   = <merged string with LABELED conflict markers>,
---     conflicts = { { start_line = N, end_line = M, ... }, ... } }
--- On diff3 failure/absence or binary input: nil, err.
function M.merge(base, target, source)
	-- explicit per-arg checks: pairs() would silently skip nil keys
	if type(base) ~= "string" then
		return nil, ("merge3.merge: base must be a string, got %s"):format(type(base))
	end
	if type(target) ~= "string" then
		return nil, ("merge3.merge: target must be a string, got %s"):format(type(target))
	end
	if type(source) ~= "string" then
		return nil, ("merge3.merge: source must be a string, got %s"):format(type(source))
	end
	local which = binary_refusal(base, target, source)
	if which then
		return nil, ("merge3: %s bytes look binary (NUL byte present) — a text merge "
			.. "would corrupt the file; manual resolution required"):format(which)
	end
	-- identity pre-checks: when two sides agree the answer is the third,
	-- trivially — and diff3 -m would otherwise emit a conflict block with
	-- confusing labels even when target and source made the IDENTICAL edit.
	if target == source then return { clean = true, result = target } end
	if base == target then return { clean = true, result = source } end
	if base == source then return { clean = true, result = target } end
	if not have_diff3() then
		return nil, "merge3: `diff3` not found on $PATH (runner-side dependency; GNU diffutils)"
	end

	local paths = { tmp_with(target), tmp_with(base), tmp_with(source) }
	if paths[1] == nil or paths[2] == nil or paths[3] == nil then
		for _, p in ipairs(paths) do if p then rm(p) end end
		return nil, "merge3: cannot stage input temp files"
	end

	-- diff3 argument order: MYFILE OLDFILE YOURFILE. Ours = target (the
	-- user's edits are the side to keep in overlaps), base = last deployed,
	-- theirs = new source. -m = --merge (markers on overlap conflicts).
	local ok, res = pcall(makac.exec, { "diff3", "-m",
		"-L", M.TARGET_LABEL, "-L", M.BASE_LABEL, "-L", M.SOURCE_LABEL,
		paths[1], paths[2], paths[3] })
	for _, p in ipairs(paths) do rm(p) end
	if not ok then
		return nil, "merge3: cannot run diff3: " .. tostring(res)
	end
	if res.code == 0 then
		return { clean = true, result = res.stdout or "" }
	end
	if res.code == 1 then
		-- overlap conflicts: stdout carries the LABELED markers
		local marked = res.stdout or ""
		local parsed = M.parse_conflicts(marked)
		return { clean = false, marked = marked, conflicts = parsed.regions }
	end
	return nil, ("merge3: diff3 failed (exit %d): %s")
		:format(res.code or -1, (res.stderr or ""):gsub("%s+$", ""))
end

--- Split a marked merge output into its conflict regions — the frontend
--- uses this to REPORT the conflicts (count/positions/labels), never to
--- prompt per hunk. Returns:
---   { regions = { { start_line=N, end_line=M, target={llines}, base={blines},
---                   new={nlines} }, ... },
---     surrounding = <non-conflict text, joined by "\n" (reporting aid)> }
--- Malformed/partial marker trails are tolerated: an unclosed region runs
--- to end of input so it is still reported.
function M.parse_conflicts(marked)
	if type(marked) ~= "string" then
		error("merge3.parse_conflicts: marked must be a string", 2)
	end
	local lines = lines_of(marked)
	local regions, surrounding = {}, {}
	local i = 1
	while i <= #lines do
		if marker_line(lines[i]) == "<" then
			local region = { start_line = i, target = {}, base = {}, new = {} }
			local part, j, closed = "target", i + 1, false
			while j <= #lines do
				local m = marker_line(lines[j])
				if m == ">" then
					region.end_line = j
					closed = true
					break
				elseif m == "<" then
					break -- nested/malformed: bail, report what we have
				elseif m == "|" then
					part = "base"
				elseif m == "=" then
					part = "new"
				else
					region[part][#region[part] + 1] = lines[j]
				end
				j = j + 1
			end
			region.end_line = region.end_line or #lines
			regions[#regions + 1] = region
			i = closed and (j + 1) or j
		else
			surrounding[#surrounding + 1] = lines[i]
			i = i + 1
		end
	end
	return { regions = regions, surrounding = table.concat(surrounding, "\n") }
end

--- Validate a user-edited merge result: true when the grammar is clean, or
--- nil + the offending line ranges { { start_line=N, end_line=M }, ... } —
--- one range per conflict region, plus one 1-line range per STRAY marker
--- line outside any region (e.g. a lone "======="). Any label text after
--- <<<<<<< / ||||||| / >>>>>>> is tolerated. The frontend REOPENS $EDITOR
--- while this returns ranges.
function M.validate_no_markers(text)
	if type(text) ~= "string" then
		error("merge3.validate_no_markers: text must be a string", 2)
	end
	local parsed = M.parse_conflicts(text)
	local ranges, in_region = {}, {}
	for _, r in ipairs(parsed.regions) do
		ranges[#ranges + 1] = { start_line = r.start_line, end_line = r.end_line }
		for ln = r.start_line, r.end_line do in_region[ln] = true end
	end
	local lines = lines_of(text)
	for ln = 1, #lines do
		if not in_region[ln] and marker_line(lines[ln]) then
			ranges[#ranges + 1] = { start_line = ln, end_line = ln }
		end
	end
	if #ranges == 0 then return true end
	table.sort(ranges, function(a, b) return a.start_line < b.start_line end)
	return nil, ranges
end

return M
