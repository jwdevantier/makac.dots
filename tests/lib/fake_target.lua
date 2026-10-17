-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- A fake target for unit tests: a directory on the host that plays the role
-- of a remote filesystem. Its $HOME is the root directory itself, so entries
-- with dest "~/.config/foo" land under the root. Commands run through
-- makac.exec with HOME pointed at the root; put/get become cp.
--
-- This exercises the exact target interface (run/put/get) the actions use,
-- WITHOUT proving quoting/ssh behaviour — that is what the black-box suites
-- (host target and ssh_real) are for. Do NOT use absolute dest paths outside
-- the root with this fake: nothing confines run() to the root directory.

local M = {}

--- root: host directory acting as the fake target's filesystem and $HOME.
function M.new(root)
	root = tostring(root)
	makac.fs.mkdir_p(root)
	local t = {
		kind = "remote",
		name = "fake:" .. root,
		root = root,
	}

	function t:run(argv, opts)
		local env = { HOME = root }
		if opts and opts.env then
			for k, v in pairs(opts.env) do env[k] = v end
		end
		return makac.exec(argv, { env = env })
	end

	function t:put(src, dst)
		local res = makac.exec({ "cp", "--", src, dst })
		if res.code ~= 0 then
			error("fake put failed: " .. (res.stderr or ""), 0)
		end
	end

	function t:get(src, dst)
		local res = makac.exec({ "cp", "--", src, dst })
		if res.code ~= 0 then
			error("fake get failed: " .. (res.stderr or ""), 0)
		end
	end

	function t:close() end

	return t
end

return M
