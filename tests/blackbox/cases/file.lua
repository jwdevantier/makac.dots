-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/file.lua — dots:file behavior exercised purely through the CLI:
-- change detection, idempotence across runs, conflict/override, mode +
-- drift repair, absent, '~' expansion. Host target; destinations target in the
-- per-case tmp dir (or under HOME=ctx.tmp), never the real home.
-- Contract under test: lib/action_file.lua (dots:file).

local h = require("harness")
local bb = require("bbctx")

h.suite("file")

-- a workflow that applies ONE inline-content entry and reports the step's
-- result as a stable marker; run it multiple times to observe idempotence
local function one_file_workflow(dest, extra_with)
	return ([[
local r = step { uses = "dots:file", name = "prime", with = %s }
print("RESULT changed=" .. tostring(r.changed))
]]):format(extra_with(dest))
end

h.case("file", "write_changed_then_ok", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/x.conf")
	bb.writef(ctx, "proj/w.lua", one_file_workflow(dest, function(d)
		return ([[{ dest = %q, content = "hello" }]]):format(d)
	end))
	local r1 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r1.code, 0, "first run exit: " .. r1.stderr)
	h.contains(r1.stdout, "RESULT changed=true", "materializing a new file reports changed")
	h.matches(h.norm(ctx, r1.stderr), "changed: %[host%] prime %(Ts%)", "changed step line on stderr")
	h.eq(ctx.read("dest/x.conf"), "hello", "content landed")
	-- idempotence across two makac run invocations
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r2.code, 0, "second run exit: " .. r2.stderr)
	h.contains(r2.stdout, "RESULT changed=false", "second run is a no-op")
	h.eq(ctx.read("dest/x.conf"), "hello", "content stable")
end)

h.case("file", "idempotent_within_one_workflow", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/a.ini")
	bb.writef(ctx, "proj/w.lua", ([[
local w = { dest = %q, content = "same" }
local r1 = step { uses = "dots:file", name = "first", with = w }
local r2 = step { uses = "dots:file", name = "second", with = w }
print("R1 changed=" .. tostring(r1.changed))
print("R2 changed=" .. tostring(r2.changed))
]]):format(dest))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "R1 changed=true")
	h.contains(r.stdout, "R2 changed=false", "hash match: same bytes, no rewrite")
end)

h.case("file", "conflict_without_override_loses_and_reports_failed", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/c.conf")
	bb.writef(ctx, "dest/c.conf", "local edit\n")
	bb.writef(ctx, "proj/w.lua", one_file_workflow(dest, function(d)
		return ([[{ dest = %q, content = "desired" }]]):format(d)
	end))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 1, "run fails when the step fails (exit): " .. r.stderr)
	h.matches(h.norm(ctx, r.stderr), "failed: %[host%] prime %(Ts%)", "failed step line")
	h.contains(r.stderr, "conflict", "conflict reason reported")
	h.contains(r.stderr, "override = false", "the rule named in the message")
	h.eq(ctx.read("dest/c.conf"), "local edit\n", "existing file byte-identical afterwards")
end)

h.case("file", "override_true_replaces_and_leaves_no_backup", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/o.conf")
	bb.writef(ctx, "dest/o.conf", "stale\n")
	bb.writef(ctx, "proj/w.lua", one_file_workflow(dest, function(d)
		return ([[{ dest = %q, content = "replacement", override = true }]]):format(d)
	end))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "RESULT changed=true", "override writes count as changed")
	h.eq(ctx.read("dest/o.conf"), "replacement", "dest replaced")
	local names = {}
	for _, e in ipairs(assert(makac.fs.listdir(ctx.path("dest")))) do
		names[#names + 1] = e.name
	end
	h.eq(#names, 1, "no backup or temp files left behind: " .. table.concat(names, ","))
	h.eq(names[1], "o.conf")
end)

h.case("file", "mode_applied_then_external_chmod_repaired", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/m.conf")
	bb.writef(ctx, "proj/w.lua", one_file_workflow(dest, function(d)
		return ([[{ dest = %q, content = "m", mode = "0600" }]]):format(d)
	end))
	local r1 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r1.code, 0, "first run exit: " .. r1.stderr)
	local st = makac.exec({ "stat", "-c", "%a", dest })
	h.eq((st.stdout:gsub("%s+$", "")), "600", "mode applied")
	-- external drift: chmod to 644, rerun repairs and reports changed
	h.eq(makac.exec({ "chmod", "644", dest }).code, 0, "chmod 644")
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r2.code, 0, "second run exit: " .. r2.stderr)
	h.contains(r2.stdout, "RESULT changed=true", "mode drift reported as changed")
	st = makac.exec({ "stat", "-c", "%a", dest })
	h.eq((st.stdout:gsub("%s+$", "")), "600", "mode repaired")
	-- settled: third run is quiet
	local r3 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r3.code, 0, "third run exit: " .. r3.stderr)
	h.contains(r3.stdout, "RESULT changed=false")
end)

h.case("file", "absent_removes_then_quiet", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local dest = ctx.path("dest/gone.conf")
	bb.writef(ctx, "dest/gone.conf", "stale")
	bb.writef(ctx, "proj/w.lua", one_file_workflow(dest, function(d)
		return ([[{ dest = %q, absent = true }]]):format(d)
	end))
	local r1 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r1.code, 0, "first run exit: " .. r1.stderr)
	h.contains(r1.stdout, "RESULT changed=true", "removal is a change")
	h.eq(ctx.exists("dest/gone.conf"), false, "file removed")
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r2.code, 0, "second run exit: " .. r2.stderr)
	h.contains(r2.stdout, "RESULT changed=false", "already absent: no-op")
end)

h.case("file", "tilde_expands_against_run_home", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	bb.writef(ctx, "proj/w.lua", one_file_workflow("~/tilde.conf", function(d)
		return ([[{ dest = %q, content = "home sweet home" }]]):format(d)
	end))
	-- HOME=ctx.tmp keeps '~' hermetic: expansion happens against the WORKFLOW
	-- RUN's HOME (host target), pointed at the per-case tmp dir
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj, env = { HOME = ctx.tmp } })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.eq(ctx.read("tilde.conf"), "home sweet home", "~/tilde.conf landed under $HOME")
end)
