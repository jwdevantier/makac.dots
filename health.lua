-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- makac.dots health check (makac's design/doctor.md): host-side prerequisites,
-- the hash strategy, plus a self-check that the library modules load.
--
-- The target-side tools the actions shell out to (`mkdir`, `mv`, `chmod`,
-- `chown`, `ln`, `test`, `rm`) run on the TARGET (host or SSH remote) and so
-- cannot be probed from here; they are POSIX utilities every supported
-- target must provide.

return function(health, pkg_name)
	local function on_path(bin)
		local ok, res = pcall(makac.exec, { "sh", "-c", "command -v " .. bin })
		if ok and res.code == 0 then
			local p = (res.stdout or ""):gsub("%s+$", "")
			if p ~= "" then return p end
		end
		return nil
	end

	health.start("programs")

	-- `sh` is used host-side for shell-outs (arg escaping, exec).
	if on_path("sh") then
		health.ok("sh found on $PATH")
	else
		health.error("sh not found", "a POSIX shell must be on $PATH")
	end

	health.start("hashing")

	-- hashing is host-side via makac.fs.sha256 (portable — no sha256sum is
	-- needed on the target): the desired bytes and the fetched current bytes
	-- are hashed on the machine running makac.
	health.ok("hashing is host-side via makac.fs.sha256 (portable)")
	-- sha256sum on PATH is an optional fast path only; not required.
	local s = on_path("sha256sum")
	if s then
		health.info("sha256sum found at " .. s .. " (optional fast path, not required)")
	else
		health.info("sha256sum not on $PATH (fine; hashing uses makac.fs.sha256)")
	end

	health.start("library")
	for _, mod in ipairs({ "glob", "journal", "materialize", "plan", "action_file", "action_apply" }) do
		local ok, err = pcall(require, pkg_name .. "/" .. mod)
		if ok then
			health.ok("require " .. pkg_name .. "/" .. mod)
		else
			health.error("cannot require " .. pkg_name .. "/" .. mod, tostring(err))
		end
	end
end
