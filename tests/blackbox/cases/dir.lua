-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/dir.lua — directory attrs (["."] in dots.lua) + dots:dir through the
-- CLI against the host target: attrs land before the children, snapshot
-- kind="dir" entries are recorded, the root-["."] DEST footgun gate,
-- dots:diff MODE reporting for dirs, and prune of orphaned directories
-- (empty → rmdir, non-empty → kept + reported).
-- Contract under test: lib/plan.lua ["."] walk, lib/action_dir.lua,
-- dispatch in lib/action_apply.lua, dir drift in lib/diff.lua, dir pruning
-- in lib/prune.lua / lib/action_prune.lua.

local h = require("harness")
local bb = require("bbctx")

h.suite("dir")

local APPLY_W = [[
local r = step { uses = "dots:apply", name = "dots",
  with = { root = "tree", dest = %q %s } }
print("APPLY changed=" .. tostring(r.changed))
print("APPLY count changed=" .. #r.out.changed)
print("APPLY count ok=" .. #r.out.ok)
print("APPLY count failed=" .. #r.out.failed)
for _, p in ipairs(r.out.failed) do print("FAILED " .. p.path .. " :: " .. p.err) end
]]

local DIFF_W = [[
local r = step { uses = "dots:diff", name = "diff",
  with = { root = "tree", dest = %q } }
print("DIFF drifted=" .. tostring(r.out.drifted))
print("DIFF mode_drift=" .. #r.out.mode_drift)
print("DIFF owner_drift=" .. #r.out.owner_drift)
print("DIFF differing=" .. #r.out.differing)
]]

local PRUNE_W = [[
local r = step { uses = "dots:prune", name = "prune",
  with = { root = "tree", dest = %q, policy = %q } }
print("PRUNE changed=" .. tostring(r.changed))
print("PRUNE deleted=" .. #r.out.deleted)
print("PRUNE forgotten=" .. #r.out.forgotten)
print("PRUNE skipped_dirs=" .. #r.out.skipped_dirs)
for _, d in ipairs(r.out.deleted) do print("DELETED " .. d.relpath) end
for _, p in ipairs(r.out.skipped_dirs) do print("KEPTDIR " .. p) end
]]

local function mode_of(ctx, rel)
	local st = makac.exec({ "stat", "-c", "%a", "--", ctx.path(rel) })
	return (st.stdout or ""):gsub("%s+$", "")
end

--- count snapshot entries whose metadata names the given kind
local function snap_kind_count(ctx, kind)
	local res = makac.exec({ "sh", "-c",
		("grep -l '\"kind\":\"%s\"' %q/* 2>/dev/null | wc -l")
			:format(kind, ctx.path("home/.makac/dots/snapshot")) })
	return tonumber(((res.stdout or ""):gsub("%s+$", "")))
end

-- tree with a managed directory: app/ gets mode 0700 from its dots.lua
-- ["."] entry; the file inside it is plain (its parent exists, with modes,
-- before it lands)
local FIXTURE = {
	["top.conf"] = "top\n",
	app = {
		["f.conf"] = "f\n",
		["dots.lua"] = [[return { ["."] = { mode = "0700" } }]],
	},
}

h.case("dir", "attrs_land_before_children_and_snapshot_includes_dirs", function(ctx)
	local proj = bb.make_project(ctx, "proj", FIXTURE)
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", APPLY_W:format(dest, ""))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY count failed=0")
	h.eq(mode_of(ctx, "home/app"), "700", "dir mode applied")
	h.eq(ctx.read("home/app/f.conf"), "f\n", "child file landed")
	h.eq(snap_kind_count(ctx, "dir"), 1, "one kind=dir snapshot entry")

	-- idempotent: the dir converges alongside the files
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.contains(r2.stdout, "APPLY changed=false", "second run converged")
	h.contains(r2.stdout, "APPLY count ok=3", "dir + 2 files all ok")

	-- mode drift on the dir is REPORTED as a MODE line, then repaired
	makac.exec({ "chmod", "755", ctx.path("home/app") })
	bb.writef(ctx, "proj/wdiff.lua", DIFF_W:format(dest))
	local rd = ctx.run({ "run", "wdiff.lua" }, { chdir = proj })
	h.contains(rd.stdout, "DIFF drifted=true")
	h.contains(rd.stdout, "DIFF mode_drift=1")
	h.contains(rd.stdout, "DIFF differing=0", "no content diff for a dir")
	h.matches(rd.stdout, "MODE .+/home/app: 755 %-> 0700", "MODE report line")
	local r3 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.contains(r3.stdout, "APPLY changed=true", "drift repaired on apply")
	h.eq(mode_of(ctx, "home/app"), "700")
end)

h.case("dir", "root_dot_entry_gateway", function(ctx)
	local proj = bb.make_project(ctx, "proj", {
		["f.conf"] = "f\n",
		-- 0711 deliberately differs from the umask-created mode so the
		-- drift is observable in check mode / diff before the gate opens
		["dots.lua"] = [[return { ["."] = { mode = "0711" } }]],
	})
	local dest = ctx.path("home")
	ctx.mkdir_p("home") -- ensure DEST exists so its mode is observable
	local before = mode_of(ctx, "home")

	-- without manage_dest_dir the root ["."] entry FAILS the step (data,
	-- non-strict), files still land, DEST itself is untouched
	bb.writef(ctx, "proj/w.lua", APPLY_W:format(dest, ""))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "non-strict exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY count failed=1")
	h.matches(r.stdout, "FAILED .+/home :: .*manage_dest_dir", "footgun error names the flag")
	h.eq(ctx.read("home/f.conf"), "f\n", "files still deploy")
	h.eq(mode_of(ctx, "home"), before, "DEST untouched without the flag")

	-- check mode still SHOWS the gated entry (diff must be able to report it)
	bb.writef(ctx, "proj/wdiff.lua", DIFF_W:format(dest))
	local rd = ctx.run({ "run", "wdiff.lua" }, { chdir = proj })
	h.contains(rd.stdout, "DIFF mode_drift=1", "diff shows the root dir drift")

	-- with the flag: applied
	bb.writef(ctx, "proj/w.lua", APPLY_W:format(dest, ", manage_dest_dir = true"))
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.contains(r2.stdout, "APPLY count failed=0")
	h.eq(mode_of(ctx, "home"), "711", "DEST mode managed once acknowledged")
end)

h.case("dir", "prune_orphaned_dirs_empty_rmdir_nonempty_kept", function(ctx)
	local proj = bb.make_project(ctx, "proj", {
		["keep.conf"] = "k\n",
		emptyd = {
			["f.conf"] = "f\n",
			["dots.lua"] = [[return { ["."] = { mode = "0700" } }]],
		},
		busyd = {
			["g.conf"] = "g\n",
			["dots.lua"] = [[return { ["."] = {} }]],
		},
	})
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", APPLY_W:format(dest, ""))
	h.eq(ctx.run({ "run", "w.lua" }, { chdir = proj }).code, 0, "apply exit")
	h.eq(snap_kind_count(ctx, "dir"), 2, "two dir entries recorded")

	-- both dirs leave the tree; emptyd's file was user-deleted (its entry
	-- auto-forgets, the target dir is now EMPTY); busyd still has a target file
	makac.exec({ "rm", "-rf", "--", proj .. "/tree/emptyd", proj .. "/tree/busyd" })
	makac.exec({ "rm", "-f", "--", ctx.path("home/emptyd/f.conf") })

	bb.writef(ctx, "proj/wprune.lua", PRUNE_W:format(dest, "delete"))
	local r = ctx.run({ "run", "wprune.lua" }, { chdir = proj })
	h.eq(r.code, 0, "prune exit: " .. r.stderr)
	h.contains(r.stdout, "PRUNE skipped_dirs=1")
	h.contains(r.stdout, "KEPTDIR busyd")
	h.matches(r.stdout, "DELETED emptyd[\r\n]", "empty dir removed via rmdir")
	h.matches(r.stdout, "DELETED busyd/g%.conf", "orphaned file inside busyd deleted")
	h.eq(ctx.exists("home/emptyd"), false, "empty orphaned dir gone")
	h.eq(ctx.exists("home/busyd"), true, "non-empty orphaned dir kept")
	h.eq(ctx.read("home/keep.conf"), "k\n", "managed dirs' siblings untouched")
	h.eq(snap_kind_count(ctx, "dir"), 1, "busyd's entry stays, emptyd's dropped")
end)
