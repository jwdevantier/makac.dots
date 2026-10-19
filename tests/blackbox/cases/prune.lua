-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/prune.lua — the dots:prune round-trip through the CLI against the
-- host target: apply a fixture tree, remove files from the tree, then
-- report → delete → re-report. Asserts target removal + snapshot entry drops,
-- vanished-target auto-forget, drift reporting, and foreign-owner safety.
-- Contract under test: lib/action_prune.lua + lib/prune.lua.

local h = require("harness")
local bb = require("bbctx")

h.suite("prune")

local APPLY_W = [[
local r = step { uses = "dots:apply", name = "dots",
  with = { root = "tree", dest = %q } }
print("APPLY changed=" .. tostring(r.changed) .. " failed=" .. #r.out.failed)
]]

local PRUNE_W = [[
local r = step { uses = "dots:prune", name = "prune",
  with = { root = "tree", dest = %q %s } }
print("PRUNE changed=" .. tostring(r.changed))
print("PRUNE orphans=" .. #r.out.orphans)
print("PRUNE deleted=" .. #r.out.deleted)
print("PRUNE forgotten=" .. #r.out.forgotten)
print("PRUNE failed=" .. #r.out.failed)
print("PRUNE foreign=" .. #r.out.foreign)
if r.out.would_delete then print("PRUNE would_delete=" .. #r.out.would_delete) end
if r.out.would_forget then print("PRUNE would_forget=" .. #r.out.would_forget) end
for _, o in ipairs(r.out.orphans) do
  print("ORPHAN " .. o.relpath .. " drifted=" .. tostring(o.drifted))
end
for _, d in ipairs(r.out.deleted) do
  print("DELETED " .. d.relpath .. " drifted=" .. tostring(d.drifted))
end
for _, p in ipairs(r.out.forgotten) do print("FORGOTTEN " .. p) end
]]

local function snapdir_count(ctx)
	local res = makac.exec({ "sh", "-c",
		"ls -1A \"" .. ctx.path("home/.makac/dots/snapshot") .. "\" 2>/dev/null | wc -l" })
	-- NOTE: the outer parens truncate gsub's second return (count)
	return tonumber(((res.stdout or ""):gsub("%s+$", "")))
end

h.case("prune", "report_then_delete_round_trip", function(ctx)
	local proj = bb.make_project(ctx, "proj", {
		["a.conf"] = "a deployed\n",
		["b.conf"] = "b deployed\n",
		["c.conf"] = "c deployed\n",
	})
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w_apply.lua", APPLY_W:format(dest))
	local r0 = ctx.run({ "run", "w_apply.lua" }, { chdir = proj })
	h.eq(r0.code, 0, "apply exit: " .. r0.stderr)
	h.eq(snapdir_count(ctx), 3, "3 snapshot entries recorded")

	-- b.conf leaves the tree (orphan, target intact); c.conf leaves the tree
	-- AND its target file was deleted by hand (auto-forget); a.conf drifted?
	-- no: make b.conf drifted so the delete report carries the flag.
	makac.exec({ "rm", "-f", "--", proj .. "/tree/b.conf", proj .. "/tree/c.conf" })
	makac.exec({ "rm", "-f", "--", ctx.path("home/c.conf") })
	makac.fs.write_file(ctx.path("home/b.conf"), "user edited\n")

	-- 1) report: nothing mutates
	bb.writef(ctx, "proj/w_prune.lua", PRUNE_W:format(dest, ""))
	local r1 = ctx.run({ "run", "w_prune.lua" }, { chdir = proj })
	h.eq(r1.code, 0, "prune report exit: " .. r1.stderr)
	h.contains(r1.stdout, "PRUNE changed=false")
	h.contains(r1.stdout, "PRUNE orphans=2")
	h.contains(r1.stdout, "PRUNE would_delete=1")
	h.contains(r1.stdout, "PRUNE would_forget=1")
	h.matches(r1.stdout, "ORPHAN b%.conf drifted=true", "drift flag in report")
	h.eq(ctx.read("home/b.conf"), "user edited\n", "report removed nothing")
	h.eq(snapdir_count(ctx), 3, "report dropped no entries")

	-- 2) delete: b.conf's target file goes, c.conf's entry is auto-forgotten
	bb.writef(ctx, "proj/w_prune.lua", PRUNE_W:format(dest, ', policy = "delete"'))
	local r2 = ctx.run({ "run", "w_prune.lua" }, { chdir = proj })
	h.eq(r2.code, 0, "prune delete exit: " .. r2.stderr)
	h.contains(r2.stdout, "PRUNE changed=true")
	h.contains(r2.stdout, "PRUNE deleted=1")
	h.contains(r2.stdout, "PRUNE forgotten=1")
	h.contains(r2.stdout, "PRUNE failed=0")
	h.matches(r2.stdout, "DELETED b%.conf drifted=true", "delete reports drift")
	h.contains(r2.stdout, "FORGOTTEN c.conf")
	h.eq(ctx.exists("home/b.conf"), false, "orphan target file deleted")
	h.eq(ctx.read("home/a.conf"), "a deployed\n", "planned file untouched")
	h.eq(snapdir_count(ctx), 1, "only a.conf's entry remains")

	-- 3) re-report: converged, nothing left
	bb.writef(ctx, "proj/w_prune.lua", PRUNE_W:format(dest, ""))
	local r3 = ctx.run({ "run", "w_prune.lua" }, { chdir = proj })
	h.contains(r3.stdout, "PRUNE orphans=0", "no orphans after delete")
end)

h.case("prune", "foreign_owner_never_touched", function(ctx)
	local proj = bb.make_project(ctx, "proj", {
		["a.conf"] = "a deployed\n",
	})
	local dest = ctx.path("home")
	-- a foreign tree (different owner id) deploys its own file into the
	-- same DEST, then stops managing it → foreign orphan from OUR viewpoint
	bb.writef(ctx, "proj/foreign.lua",
		("step { uses = 'dots:apply', name = 'foreign', with = {"
			.. " root = 'ftree', dest = %q, tree = 'bootstrap' } }"):format(dest))
	bb.tree(ctx, "proj/ftree", { ["foreign.conf"] = "foreign\n" })
	bb.writef(ctx, "proj/w_apply.lua", APPLY_W:format(dest))

	h.eq(ctx.run({ "run", "foreign.lua" }, { chdir = proj }).code, 0, "foreign deploy")
	h.eq(ctx.run({ "run", "w_apply.lua" }, { chdir = proj }).code, 0, "our deploy")
	h.eq(snapdir_count(ctx), 2, "both trees recorded")

	-- foreign.conf is an orphan of 'bootstrap' but foreign TO US: our prune
	-- (delete!) must report it and leave it strictly alone
	bb.writef(ctx, "proj/w_prune.lua", PRUNE_W:format(dest, ', policy = "delete"'))
	local r = ctx.run({ "run", "w_prune.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "PRUNE orphans=0", "no orphans of OUR tree")
	h.contains(r.stdout, "PRUNE foreign=1", "one foreign owner seen")
	h.contains(r.stdout, "PRUNE deleted=0")
	h.contains(r.stderr, "owned by 'bootstrap' — skipped", "foreign summary line")
	h.eq(ctx.read("home/foreign.conf"), "foreign\n", "foreign target file intact")
	h.eq(snapdir_count(ctx), 2, "foreign snapshot entry intact")
end)
