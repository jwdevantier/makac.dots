-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- glob matching for `$ignore` patterns:
-- `*` matches within one path segment, `**` across segments, a trailing
-- `/` matches a directory and everything under it. Only `*` and `**` are
-- special (character classes are not supported). Patterns are relative to
-- the directory carrying the dots.lua.

local M = {}

local function escape(c)
	return "%" .. c
end

--- Translate one `*`/`**` glob (no trailing `/`) to an anchored Lua pattern.
--- `**` spans `/`; a plain `*` never does.
local function to_lua_pattern(g)
	local parts = {}
	local i = 1
	local n = #g
	while i <= n do
		local c = g:sub(i, i)
		if c == "*" then
			if g:sub(i + 1, i + 1) == "*" then
				parts[#parts + 1] = ".*"
				i = i + 2
			else
				parts[#parts + 1] = "[^/]*"
				i = i + 1
			end
		else
			parts[#parts + 1] = (c:gsub("%W", escape))
			i = i + 1
		end
	end
	return "^" .. table.concat(parts) .. "$"
end

--- Does `pattern` match relpath (relative, `/`-separated, no leading slash)?
--- A trailing `/` in the pattern matches that directory itself and anything
--- under it.
function M.match(pattern, relpath)
	if type(pattern) ~= "string" then
		error("glob pattern must be a string, got " .. type(pattern), 2)
	end
	local g = pattern
	if g:sub(-1) == "/" then
		g = g:sub(1, -2)
		if g == "" then
			return false
		end
		-- the directory itself ...
		if M.match(g, relpath) then
			return true
		end
		-- ... or any descendant: match the glob plus a leading "anything under"
		return relpath:match(to_lua_pattern(g .. "/**")) ~= nil
	end
	return relpath:match(to_lua_pattern(g)) ~= nil
end

return M
