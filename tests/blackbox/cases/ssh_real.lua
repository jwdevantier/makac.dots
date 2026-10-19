-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/ssh_real.lua — the package against a REAL ssh target, jwd@workpc.lan
-- (Linux/NixOS, key auth, BatchMode). This is the package's whole point:
-- the same dots:file/dots:link/dots:apply code path serves host and remote;
-- the final case is the differential proof (identical trees on both targets).
--
-- Only subdirectories under /tmp/makac-dots-test/ named after the case are
-- touched, and each is removed after its case (pass or fail). The root dir
-- itself is left in place.
--
-- Auto-skip: if workpc is unreachable (or DOTS_BB_SSH=0), the whole suite
-- opts out with one line instead of failing.

local h = require("harness")
local bb = require("bbctx")

local REMOTE = "/tmp/makac-dots-test"

--- ssh to jwd@workpc.lan running a shell snippet; asserts success by default.
local function rsh(cmd, want)
	local r = makac.exec({ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
		"jwd@workpc.lan", cmd }, { timeout_s = 60 })
	if want == nil then want = 0 end
	if want ~= false then
		h.eq(r.code, want, ("remote `%s` exit (stderr: %s)"):format(cmd, r.stderr))
	end
	return r
end

local function rcat(path)
	return rsh(("cat '%s'"):format(path)).stdout
end

local function rmode(path)
	return (rsh(("stat -c %%a '%s'"):format(path)).stdout:gsub("%s+$", ""))
end

-- --- reachability gate --------------------------------------------------------
-- evaluated at REQUIRE time: unreachable remote means "no suite", so an
-- offline dev machine still gets a green run of everything else.

local reachable = os.getenv("DOTS_BB_SSH") ~= "0"
	and makac.exec({ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
		"jwd@workpc.lan", "true" }, { timeout_s = 15 }).code == 0

if not reachable then
	print("# skip: workpc unreachable")
	return
end

rsh(("mkdir -p '%s'"):format(REMOTE))

h.suite("ssh_real")

-- --- suite plumbing -----------------------------------------------------------

--- Wrap a case body with its own scratch subdir on the remote:
--- cleaned before AND after (pass or fail), never touching anything else.
local function rcase(name, fn)
	h.case("ssh_real", name, function(ctx)
		local dest = REMOTE .. "/" .. name
		rsh(("rm -rf '%s' && mkdir -p '%s'"):format(dest, dest))
		local ok, err = pcall(fn, ctx, dest)
		rsh(("rm -rf '%s'"):format(dest))
		if not ok then error(err, 2) end
	end)
end

local TARGET_LUA = [[
local target = makac.new_ssh_target("workpc", { host = "workpc.lan", user = "jwd",
  options = { BatchMode = "yes", StrictHostKeyChecking = "accept-new" } })
]]

--- workflow applying tree/ to <dest> over ssh, with stable result markers.
local function apply_workflow(dest, extra)
	return TARGET_LUA .. ([[
local r = step { uses = "dots:apply", name = "dots",
  with = { root = "tree", dest = %q, target = target %s } }
print("APPLY changed=" .. tostring(r.changed))
print("APPLY count changed=" .. #r.out.changed)
print("APPLY count ok=" .. #r.out.ok)
print("APPLY count failed=" .. #r.out.failed)
for _, p in ipairs(r.out.changed) do print("CHANGED " .. p) end
for _, p in ipairs(r.out.failed) do print("FAILED " .. p.path) end
]]):format(dest, extra or "")
end

-- nested dirs, a dots.lua with a $default_attrs mode at the root, and a renderer in a
-- subdirectory (renderer definitions dofile'd from the project root —
-- renders on the HOST, ships the rendered bytes). dots.lua files are policies of
-- their OWN directory: sub/ carries $override = true so drift there repairs
-- itself, while the tree root keeps the call-site default (override = false)
-- so a pre-existing differing main.conf is a conflict.
local TREE = {
	["main.conf"] = "ssh main\n",
	["dots.lua"] = [[return { ["$default_attrs"] = { mode = "0600" } }]],
	sub = {
		["inner.conf"] = "ssh inner\n",
		["rendered.conf"] = "quiet text\n",
		["dots.lua"] = [=[
local d = dofile(PROJECT_DIR .. "/defaults.lua")
return {
  ["$override"] = true,
  ["rendered.conf"] = { renderer = d.upper },
}
]=],
	},
}

local DEFAULTS_LUA = [[
return {
  upper = function(content) return content:upper() end,
}
]]

local function fixture_project(ctx)
	local proj = bb.make_project(ctx, "proj", TREE)
	bb.writef(ctx, "proj/defaults.lua", DEFAULTS_LUA)
	return proj
end

--- Apply TREE to <dest> until the asserted state; returns the last run result.
local function run_apply(ctx, proj, dest, extra)
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest, extra))
	return ctx.run({ "run", "w.lua" }, { chdir = proj, timeout_s = 120 })
end

-- --- cases --------------------------------------------------------------------

rcase("apply_a_tree", function(ctx, dest)
	local proj = fixture_project(ctx)
	local r = run_apply(ctx, proj, dest)
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true", "first apply changes")
	h.contains(r.stdout, "APPLY count changed=3", "3 files shipped")
	h.contains(r.stdout, "APPLY count failed=0")
	h.eq(rcat(dest .. "/main.conf"), "ssh main\n", "root file landed")
	h.eq(rcat(dest .. "/sub/inner.conf"), "ssh inner\n", "nested file landed")
	h.eq(rcat(dest .. "/sub/rendered.conf"), "QUIET TEXT\n",
		"renderer ran on the host, rendered bytes landed")
	h.eq(rmode(dest .. "/main.conf"), "600", "$default_attrs mode applied remotely")
	h.eq(rmode(dest .. "/sub/inner.conf"), "600", "mode in nested dir")
	-- per-file step lines carry the ssh target name
	local norm = h.norm(ctx, r.stderr)
	h.contains(norm, "changed: [workpc] " .. dest .. "/main.conf (Ts)", "per-file line: main.conf")
	h.contains(norm, "changed: [workpc] " .. dest .. "/sub/rendered.conf (Ts)",
		"per-file line: rendered.conf")
	h.matches(norm, "changed: %[workpc%] dots %(Ts%)", "outer line")
end)

rcase("idempotent", function(ctx, dest)
	local proj = fixture_project(ctx)
	local r1 = run_apply(ctx, proj, dest)
	h.eq(r1.code, 0, "first run exit: " .. r1.stderr)
	h.contains(r1.stdout, "APPLY changed=true")
	local r2 = run_apply(ctx, proj, dest)
	h.eq(r2.code, 0, "second run exit: " .. r2.stderr)
	h.contains(r2.stdout, "APPLY changed=false", "second run is a no-op")
	h.contains(r2.stdout, "APPLY count ok=3", "all entries report ok")
	h.contains(r2.stdout, "APPLY count changed=0", "changed=false everywhere")
	h.matches(h.norm(ctx, r2.stderr), "ok: %[workpc%] dots %(Ts%)", "outer line ok")
end)

rcase("drift_repair", function(ctx, dest)
	local proj = fixture_project(ctx)
	h.eq(run_apply(ctx, proj, dest).code, 0, "first apply")
	rsh(("printf 'CLOBBBER\\n' > '%s/sub/inner.conf'"):format(dest))
	h.eq(rcat(dest .. "/sub/inner.conf"), "CLOBBBER\n", "drift planted")
	local r = run_apply(ctx, proj, dest)
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true", "drift detected")
	h.contains(r.stdout, "APPLY count changed=1", "exactly the drifted file")
	h.contains(r.stdout, "CHANGED " .. dest .. "/sub/inner.conf", "drifted path named")
	h.eq(rcat(dest .. "/sub/inner.conf"), "ssh inner\n", "content restored")
end)

rcase("conflict_remote", function(ctx, dest)
	local proj = fixture_project(ctx)
	-- plant a differing local file BEFORE the first apply; tree root has no
	-- $override → default false → conflict on main.conf, siblings still ship
	rsh(("printf 'local edit\\n' > '%s/main.conf'"):format(dest))
	local r = run_apply(ctx, proj, dest)
	h.eq(r.code, 0, "apply stays non-fatal: run succeeds: " .. r.stderr)
	h.contains(r.stdout, "APPLY count failed=1", "failure is data")
	h.contains(r.stdout, "FAILED " .. dest .. "/main.conf", "failed path named")
	h.contains(r.stderr, "conflict", "the reason is written to stderr")
	h.eq(rcat(dest .. "/main.conf"), "local edit\n",
		"the conflicting remote file is untouched")
	h.eq(rcat(dest .. "/sub/inner.conf"), "ssh inner\n", "siblings applied")
end)

rcase("link_remote", function(ctx, dest)
	local proj = bb.make_project(ctx, "proj")
	-- payload file valid on the remote; the symlink stores the ABSOLUTE path
	local payload = dest .. "/payload.txt"
	bb.writef(ctx, "proj/w.lua", TARGET_LUA .. ([[
step { uses = "dots:file", name = "payload", target = target,
  with = { dest = %q, content = "payload\n" } }
local r = step { uses = "dots:link", name = "ln", target = target,
  with = { dest = %q, link = %q } }
print("LINK changed=" .. tostring(r.changed))
local r2 = step { uses = "dots:link", name = "ln2", target = target,
  with = { dest = %q, link = %q } }
print("LINK2 changed=" .. tostring(r2.changed))
]]):format(payload, dest .. "/current", payload, dest .. "/current", payload))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj, timeout_s = 120 })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "LINK changed=true", "first link creation changes")
	h.contains(r.stdout, "LINK2 changed=false", "same link is a no-op")
	h.eq(rsh(("readlink '%s/current'"):format(dest)).stdout:gsub("%s+$", ""),
		payload, "symlink stores the absolute target verbatim")
	h.eq(rcat(dest .. "/current"), "payload\n", "resolution works on the remote")
end)

rcase("mode_and_owner", function(ctx, dest)
	local proj = bb.make_project(ctx, "proj")
	-- mode applied on the remote; owner omitted entirely (no root here —
	-- chown-to-other is out of scope); asserting no spurious err
	bb.writef(ctx, "proj/w.lua", TARGET_LUA .. ([[
local r = step { uses = "dots:file", name = "m", target = target,
  with = { dest = %q, content = "m\n", mode = "0640" } }
print("MODE changed=" .. tostring(r.changed))
local r2 = step { uses = "dots:file", name = "m2", target = target,
  with = { dest = %q, content = "m\n", mode = "0640" } }
print("MODE2 changed=" .. tostring(r2.changed))
]]):format(dest .. "/m.conf", dest .. "/m.conf"))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj, timeout_s = 120 })
	h.eq(r.code, 0, "no spurious err when owner is omitted: " .. r.stderr)
	h.contains(r.stdout, "MODE changed=true")
	h.contains(r.stdout, "MODE2 changed=false", "mode settled after one run")
	h.eq(rmode(dest .. "/m.conf"), "640", "0640 applied on the remote")
	-- owner is whatever ssh user created it as (jwd) — just proving nothing
	-- was attempted on that axis
	h.eq(rsh(("stat -c %%U '%s/m.conf'"):format(dest)).stdout:gsub("%s+$", ""),
		"jwd", "owner stays the ssh user")
end)

rcase("check_mode", function(ctx, dest)
	local proj = fixture_project(ctx)
	h.eq(run_apply(ctx, proj, dest).code, 0, "first apply")
	rsh(("printf 'CLOBBBER\\n' > '%s/sub/inner.conf'"):format(dest))
	local r = run_apply(ctx, proj, dest, ", check = true")
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true", "check reports would-change")
	h.contains(r.stdout, "CHANGED " .. dest .. "/sub/inner.conf", "drift named")
	h.eq(rcat(dest .. "/sub/inner.conf"), "CLOBBBER\n",
		"check=true leaves the remote untouched")
	h.matches(h.norm(ctx, r.stderr), "changed: %[workpc%] dots %(Ts%)",
		"would-change reported as changed lines")
	-- converged tree checks clean
	rsh(("rm -rf '%s' && mkdir -p '%s'"):format(dest, dest))
	h.eq(run_apply(ctx, proj, dest).code, 0, "reapply")
	local r2 = run_apply(ctx, proj, dest, ", check = true")
	h.eq(r2.code, 0, "second check exit: " .. r2.stderr)
	h.contains(r2.stdout, "APPLY changed=false", "converged remote checks clean")
end)

rcase("differential_host_vs_ssh", function(ctx, dest)
	-- the differential test: apply THE SAME
	-- tree to the host and to the remote; the resulting file trees must be
	-- byte-identical.
	local proj = fixture_project(ctx)
	local hostdest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", TARGET_LUA .. ([[
local r1 = step { uses = "dots:apply", name = "dots-host",
  with = { root = "tree", dest = %q } }
print("HOST count changed=" .. #r1.out.changed)
local r2 = step { uses = "dots:apply", name = "dots-ssh",
  with = { root = "tree", dest = %q, target = target } }
print("SSH count changed=" .. #r2.out.changed)
]]):format(hostdest, dest))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj, timeout_s = 120 })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "HOST count changed=3")
	h.contains(r.stdout, "SSH count changed=3")
	-- sha256 walk of both trees, from each tree's root, sorted
	local walk = "cd %s && find . -type f | sort | xargs sha256sum"
	local l = makac.exec({ "sh", "-c", ("cd '%s' && find . -type f | sort | xargs sha256sum"):format(hostdest) })
	h.eq(l.code, 0, "host walk: " .. (l.stderr or ""))
	local rr = rsh(("cd '%s' && find . -type f | sort | xargs sha256sum"):format(dest))
	h.eq(rr.stdout, l.stdout, "byte-identical trees (same relphs + same sha256)")
end)

rcase("dir_attrs_remote", function(ctx, dest)
	-- directory attrs over ssh: ["."] entries land the managed dir with its
	-- mode before children, and rerun converges
	local proj = bb.make_project(ctx, "proj", {
		["top.conf"] = "top\n",
		app = {
			["f.conf"] = "f\n",
			["dots.lua"] = [[return { ["."] = { mode = "0700" } }]],
		},
	})
	local r = run_apply(ctx, proj, dest)
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY count failed=0")
	h.eq(rmode(dest .. "/app"), "700", "dir mode applied remotely")
	h.eq(rcat(dest .. "/app/f.conf"), "f\n", "child file landed")
	h.eq(rcat(dest .. "/top.conf"), "top\n")
	-- drift on the dir mode is repaired remotely
	rsh(("chmod 755 '%s/app'"):format(dest))
	local r2 = run_apply(ctx, proj, dest)
	h.eq(r2.code, 0, "exit: " .. r2.stderr)
	h.contains(r2.stdout, "APPLY changed=true", "dir mode drift detected")
	h.eq(rmode(dest .. "/app"), "700", "dir mode repaired")
	local r3 = run_apply(ctx, proj, dest)
	h.contains(r3.stdout, "APPLY changed=false", "converged: dir entry ok")
end)
