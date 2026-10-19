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

	-- diff3 is a runner-side dependency of lib/merge3.lua only — deployment
	-- never needs it, so a missing diff3 is informational, not an error.
	local d3 = on_path("diff3")
	if d3 then
		health.ok("diff3 found at " .. d3 .. " (merge3 conflict machinery available)")
	else
		health.info("diff3 not on $PATH (fine; only frontends using lib/merge3 need it)")
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
	for _, mod in ipairs({ "glob", "diff", "materialize", "plan", "snapshot", "classify", "prune", "merge3", "action_file", "action_dir", "action_apply", "action_diff", "action_prune" }) do
		local ok, err = pcall(require, pkg_name .. "/" .. mod)
		if ok then
			health.ok("require " .. pkg_name .. "/" .. mod)
		else
			health.error("cannot require " .. pkg_name .. "/" .. mod, tostring(err))
		end
	end
end
