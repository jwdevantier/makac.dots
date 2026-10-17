-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- Target-agnostic file engine for makac.dots. Every destination-side
-- operation goes through
-- the target interface (run/put/get) so the same code serves the host target
-- and an SSH target alike; only host-side scratch work (temp files, hashing
-- desired bytes) uses makac.fs / makac.exec.
--
-- All functions return (value) or (nil, err) — callers turn err into action
-- results; nothing here raises on purpose.

local M = {}

-- per-target $HOME cache
local home_cache = setmetatable({}, { __mode = "k" })

--- The target account's $HOME (cached per target).
function M.target_home(target)
	local h = home_cache[target]
	if h then return h end
	local ok, res = pcall(target.run, target, { "sh", "-c", [[printf %s "$HOME"]] })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "could not resolve $HOME on the target: " .. (res.stderr or "")
	end
	h = (res.stdout or ""):gsub("%s+$", "")
	if h == "" then return nil, "could not resolve $HOME on the target (empty)" end
	home_cache[target] = h
	return h
end

--- Resolve a user dest against the target. "~"/"~/" expand against the
--- target session's $HOME; absolute paths pass through. Everything else is
--- REJECTED: relative dests would mean the ambient cwd of whatever ran the
--- command (host: the makac process's cwd; ssh: the remote login dir), which
--- is the opposite of a declared end-state. "~user" is unsupported; ".."
--- segments are rejected (a config manager never needs them).
--- Returns (path) or (nil, err).
function M.resolve(target, path)
	for seg in (path .. "/"):gmatch("(.-)/") do
		if seg == ".." then
			return nil, ("dest %q contains a '..' segment"):format(path)
		end
	end
	if path == "~" then
		return M.target_home(target)
	end
	if path:sub(1, 2) == "~/" then
		local home, err = M.target_home(target)
		if not home then return nil, err end
		return home .. "/" .. path:sub(3)
	end
	if path:sub(1, 1) == "~" then
		return nil, ("dest %q: '~user' form is not supported; use '~/' or an absolute path")
			:format(path)
	end
	if path:sub(1, 1) ~= "/" then
		return nil, ("dest %q is relative; use '~/...' or an absolute path")
			:format(path)
	end
	return path
end

--- Parent directory of an absolute path (nil when there is none).
function M.parent_dir(path)
	local d = path:match("^(.+)/[^/]+$")
	if d == "" then return "/" end
	return d
end

local KIND_SCRIPT = [=[
if [ -L "$1" ]; then echo link
elif [ -d "$1" ]; then echo dir
elif [ -f "$1" ]; then echo file
elif [ -e "$1" ]; then echo other
else echo absent; fi
]=]

--- What exists at path on the target: "absent"|"file"|"dir"|"link"|"other".
function M.remote_kind(target, path)
	local ok, res = pcall(target.run, target, { "sh", "-c", KIND_SCRIPT, "sh", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "inspecting '" .. path .. "' failed: " .. (res.stderr or "")
	end
	-- NOTE: the outer parens truncate gsub's second return (the
	-- substitution count) so callers see (value) or (nil, err), never
	-- (value, 1) on success.
	return ((res.stdout or ""):gsub("%s+$", ""))
end

--- Current target of the symlink at path (nothing more; no -f resolution).
function M.readlink(target, path)
	local ok, res = pcall(target.run, target, { "sh", "-c", 'readlink "$1"', "sh", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "readlink '" .. path .. "' failed: " .. (res.stderr or "")
	end
	return ((res.stdout or ""):gsub("%s+$", ""))
end

--- Create a symlink at dest pointing at link (link stored as given, relative
--- or absolute). force=true replaces an existing symlink at dest (ln -sfn).
function M.symlink(target, dest, link, force)
	local argv
	if force then
		argv = { "ln", "-sfn", "--", link, dest }
	else
		argv = { "ln", "-s", "--", link, dest }
	end
	local ok, res = pcall(target.run, target, argv)
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "ln '" .. dest .. "' failed: " .. (res.stderr or "")
	end
	return true
end

--- SHA256 (hex) of the file at path on the target: fetched to a host temp and
--- hashed host-side (portable — no sha256sum is needed on the target).
function M.remote_sha256(target, path)
	local tmp = tostring(makac.fs.mktemp_file("dots-"))
	local ok, err = pcall(target.get, target, path, tmp)
	if not ok then
		pcall(makac.exec, { "rm", "-f", tmp })
		return nil, "could not fetch '" .. path .. "': " .. tostring(err)
	end
	local sha, serr = makac.fs.sha256(tmp)
	pcall(makac.exec, { "rm", "-f", tmp })
	if not sha then return nil, tostring(serr) end
	return sha
end

local function statf(target, path, fmt)
	local ok, res = pcall(target.run, target, { "stat", "-c", fmt, "--", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "stat '" .. path .. "' failed: " .. (res.stderr or "")
	end
	return ((res.stdout or ""):gsub("%s+$", ""))
end

--- Octal permission digits of the remote path ("644"), via GNU/BusyBox stat.
function M.remote_mode(target, path)
	return statf(target, path, "%a")
end

--- "user:group" of the remote path.
function M.remote_owner(target, path)
	return statf(target, path, "%U:%G")
end

--- Build the desired bytes of an entry: inline `content` or `src` read
--- host-side (relative to `root`, the entry's tree root), then the renderer
--- (content -> content) when present. The post-render bytes are what get
--- hashed and written.
function M.desired_bytes(with, root)
	local content
	if with.content ~= nil then
		if type(with.content) ~= "string" then
			return nil, "'content' must be a string, got " .. type(with.content)
		end
		content = with.content
	elseif with.src ~= nil then
		if type(with.src) ~= "string" then
			return nil, "'src' must be a string, got " .. type(with.src)
		end
		local p = with.src
		if p:sub(1, 1) ~= "/" and p:sub(1, 1) ~= "~" then
			if type(root) ~= "string" or root == "" then
				return nil, ("src '%s' is relative but no tree root was given"):format(p)
			end
			p = root .. "/" .. p
		end
		local data, rerr = makac.fs.read_file(p)
		if data == nil then
			return nil, ("cannot read src '%s': %s"):format(p, tostring(rerr))
		end
		content = data
	else
		return nil, "entry has neither 'content' nor 'src'"
	end
	if with.renderer ~= nil then
		if type(with.renderer) ~= "function" then
			return nil, "'renderer' must be a function(content) -> string"
		end
		local ok, out = pcall(with.renderer, content)
		if not ok then return nil, "renderer failed: " .. tostring(out) end
		if type(out) ~= "string" then
			return nil, "renderer must return a string, got " .. type(out)
		end
		content = out
	end
	return content
end

--- mkdir -p the parent directories of path on the target.
function M.mkdir_parents(target, path)
	local parent = M.parent_dir(path)
	if parent == nil then return true end
	local ok, res = pcall(target.run, target, { "mkdir", "-p", "--", parent })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "mkdir -p '" .. parent .. "' failed: " .. (res.stderr or "")
	end
	return true
end

--- Write bytes to path on the target, temp-then-move: build in a host temp,
--- put to a sibling temp on the target, mv into place (atomic within the
--- target's filesystem). The landed file has mode 0600; callers apply
--- mode/owner explicitly when the entry asks for them.
function M.write_file(target, path, bytes)
	local parent = M.parent_dir(path) or "."
	local base = path:match("[^/]+$") or path
	local htmp = tostring(makac.fs.mktemp_file("dots-"))
	local hbase = htmp:match("[^/]+$")
	local wok, werr = pcall(makac.fs.write_file, htmp, bytes)
	if not wok then
		pcall(makac.exec, { "rm", "-f", htmp })
		return nil, "host temp write failed: " .. tostring(werr)
	end
	local rtmp = ("%s/.%s.%s.tmp"):format(parent, base, hbase)
	local pok, perr = pcall(target.put, target, htmp, rtmp)
	pcall(makac.exec, { "rm", "-f", htmp })
	if not pok then return nil, "put to target failed: " .. tostring(perr) end
	local ok, res = pcall(target.run, target, { "mv", "-f", "--", rtmp, path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		pcall(target.run, target, { "rm", "-f", "--", rtmp })
		return nil, "mv into place failed: " .. (res.stderr or "")
	end
	return true
end

--- Remove a non-directory path on the target (caller must have checked the
--- kind; directories are never removed).
function M.remove_path(target, path)
	local ok, res = pcall(target.run, target, { "rm", "-f", "--", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "rm '" .. path .. "' failed: " .. (res.stderr or "")
	end
	return true
end

--- chmod path on the target; mode is an octal string like "0644".
function M.apply_mode(target, path, mode)
	if type(mode) ~= "string" or not mode:match("^0?[0-7][0-7][0-7][0-7]?$") then
		return nil, "mode must be an octal string like '0644', got " .. tostring(mode)
	end
	local ok, res = pcall(target.run, target, { "chmod", mode, "--", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "chmod '" .. path .. "' failed: " .. (res.stderr or "")
	end
	return true
end

--- chown path on the target; owner is "user:group" or "user" (needs the
--- privilege for what it asks).
function M.apply_owner(target, path, owner)
	if type(owner) ~= "string" or owner == "" then
		return nil, "owner must be a string like 'user:group', got " .. tostring(owner)
	end
	local ok, res = pcall(target.run, target, { "chown", owner, "--", path })
	if not ok then return nil, tostring(res) end
	if res.code ~= 0 then
		return nil, "chown '" .. path .. "' failed: " .. (res.stderr or "")
	end
	return true
end

--- Normalize an octal mode string for comparison ("0644" == "644").
function M.mode_eq(a, b)
	local na, nb = tonumber(a, 8), tonumber(b, 8)
	return na ~= nil and nb ~= nil and na == nb
end

--- Does remote "user:group" match the entry's owner ("user:group" or "user")?
function M.owner_eq(remote, want)
	if want:find(":", 1, true) then
		return remote == want
	end
	return remote:match("^([^:]+):") == want
end

return M
