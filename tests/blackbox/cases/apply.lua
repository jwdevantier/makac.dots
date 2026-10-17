-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/apply.lua — dots:apply + the tree walk/dots.lua machinery through the
-- CLI: a nested tree with $default_attrs/$ignore in dots.lua and a renderer entry,
-- idempotence, single-file drift repair, conflict as non-fatal data (and its
-- strict=true counterpart), check=true reporting without writing, and the
-- files= escape hatch.
-- Contract under test: lib/action_apply.lua + lib/plan.lua.

local h = require("harness")
local bb = require("bbctx")

h.suite("apply")

-- renderer definitions available to dots.lua files via dofile(PROJECT_DIR .. ...)
local DEFAULTS_LUA = [[
return {
  upper = function(content) return content:upper() end,
}
]]

-- the canonical fixture tree:
--   tree/top.conf        ($default_attrs mode 0600 applies; override=false entry)
--   tree/notes.bak       ($ignore "*.bak": never shipped)
--   tree/app/dots.lua    (theme.conf gets the renderer)
--   tree/app/config.toml ($override=true at tree level: drift converges)
--   tree/app/theme.conf  (uppercased on the way out)
-- The override split exercises the precedence (per-entry beats $override)
-- and the two failure modes: drift under $override repairs, a pre-existing
-- differing file under override=false conflicts. NOTE: dots.lua policies are
-- per-directory policies (no inheritance), so each directory names its own.
local FIXTURE = {
	["top.conf"] = "top-level\n",
	["notes.bak"] = "MUST NOT BE SHIPPED\n",
	["dots.lua"] = [=[
return {
  ["$default_attrs"] = { mode = "0600" },
  ["$ignore"] = { "*.bak" },
  ["top.conf"] = { override = false },
}
]=],
	app = {
		["config.toml"] = "name = 'dots'\n",
		["theme.conf"] = "theme is lowercased\n",
		["dots.lua"] = [=[
local defaults = dofile(PROJECT_DIR .. "/defaults.lua")
return {
  ["$override"] = true,
  ["theme.conf"] = { renderer = defaults.upper },
}
]=],
	},
}

--- workflow applying tree/ to <dest> and printing stable result markers.
local function apply_workflow(dest, extra)
	return ([[
local r = step { uses = "dots:apply", name = "dots",
  with = { root = "tree", dest = %q %s } }
print("APPLY changed=" .. tostring(r.changed))
print("APPLY count changed=" .. #r.out.changed)
print("APPLY count ok=" .. #r.out.ok)
print("APPLY count failed=" .. #r.out.failed)
for _, p in ipairs(r.out.changed) do print("CHANGED " .. p) end
for _, p in ipairs(r.out.failed) do print("FAILED " .. p.path) end
]]):format(dest, extra or "")
end

local function fixture_project(ctx)
	local proj = bb.make_project(ctx, "proj", FIXTURE)
	bb.writef(ctx, "proj/defaults.lua", DEFAULTS_LUA)
	return proj
end

h.case("apply", "tree_with_policy_all_files_land", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true", "first apply changes")
	h.contains(r.stdout, "APPLY count changed=3", "3 files shipped")
	h.contains(r.stdout, "APPLY count failed=0")
	h.eq(ctx.read("home/top.conf"), "top-level\n", "top.conf landed")
	h.eq(ctx.read("home/app/config.toml"), "name = 'dots'\n", "config.toml landed")
	h.eq(ctx.read("home/app/theme.conf"), "THEME IS LOWERCASED\n",
		"renderer ran (output is what lands)")
	h.eq(ctx.exists("home/notes.bak"), false, "$ignore '*.bak' not shipped")
	h.not_contains(r.stderr, "notes.bak", "no step line for the ignored file")
	-- per-file step lines on stderr (inner step name is the entry's dest)
	local norm = h.norm(ctx, r.stderr)
	h.matches(norm, "changed: %[host%] <TMP>/home/top%.conf %(Ts%)", "per-file line: top.conf")
	h.matches(norm, "changed: %[host%] <TMP>/home/app/config%.toml %(Ts%)", "per-file line: config.toml")
	h.matches(norm, "changed: %[host%] <TMP>/home/app/theme%.conf %(Ts%)", "per-file line: theme.conf")
	h.matches(norm, "changed: %[host%] dots %(Ts%)", "outer dots:apply line is changed")
	-- $default_attrs mode 0600 on every shipped file
	for _, rel in ipairs({ "home/top.conf", "home/app/config.toml", "home/app/theme.conf" }) do
		local st = makac.exec({ "stat", "-c", "%a", ctx.path(rel) })
		h.eq((st.stdout:gsub("%s+$", "")), "600", "mode of " .. rel)
	end
end)

h.case("apply", "rerun_is_idempotent", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest))
	h.eq(ctx.run({ "run", "w.lua" }, { chdir = proj }).code, 0, "first run")
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "second run exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=false", "converged: nothing changed")
	h.contains(r.stdout, "APPLY count ok=3", "all files ok")
	local norm = h.norm(ctx, r.stderr)
	h.matches(norm, "ok: %[host%] <TMP>/home/top%.conf %(Ts%)", "per-file ok line")
	h.matches(norm, "ok: %[host%] dots %(Ts%)", "outer line ok")
end)

h.case("apply", "single_file_drift_repairs_only_that_file", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest))
	h.eq(ctx.run({ "run", "w.lua" }, { chdir = proj }).code, 0, "first run")
	makac.fs.write_file(ctx.path("home/app/config.toml"), "name = 'VIOLATED'\n")
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true")
	h.contains(r.stdout, "APPLY count changed=1", "exactly the drifted file changed")
	h.contains(r.stdout, "CHANGED " .. dest .. "/app/config.toml", "the drifted file named")
	h.eq(ctx.read("home/app/config.toml"), "name = 'dots'\n", "content repaired")
end)

h.case("apply", "conflict_is_data_run_succeeds_siblings_apply", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	-- a pre-existing, differing top.conf conflicts (override defaults false)
	bb.writef(ctx, "home/top.conf", "local edit, not ours\n")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "dots:apply leaves err unset: the run SUCCEEDS: " .. r.stderr)
	h.contains(r.stdout, "APPLY count failed=1", "failure is data in out.failed")
	h.contains(r.stdout, "FAILED " .. dest .. "/top.conf", "failed path named")
	h.matches(h.norm(ctx, r.stderr), "failed: %[host%] <TMP>/home/top%.conf %(Ts%)",
		"the failing file logs its own failed line")
	h.contains(r.stderr, "conflict", "the conflict reason is reported")
	h.eq(ctx.read("home/top.conf"), "local edit, not ours\n", "loser untouched")
	h.eq(ctx.read("home/app/config.toml"), "name = 'dots'\n", "siblings still applied")
	h.eq(ctx.read("home/app/theme.conf"), "THEME IS LOWERCASED\n", "siblings still applied")
	h.matches(h.norm(ctx, r.stderr), "changed: %[host%] dots %(Ts%)",
		"outer line reports the partial change")
end)

h.case("apply", "strict_turns_failures_into_a_run_failure", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	bb.writef(ctx, "home/top.conf", "local edit, not ours\n")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest, ", strict = true"))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.truthy(r.code ~= 0, "strict: run exit " .. tostring(r.code))
	h.matches(h.norm(ctx, r.stderr), "failed: %[host%] dots %(Ts%)", "outer step fails")
	h.contains(r.stderr, "strict", "the strict reason named")
	-- siblings still converged BEFORE the err was raised
	h.eq(ctx.read("home/app/config.toml"), "name = 'dots'\n")
end)

h.case("apply", "check_reports_without_writing", function(ctx)
	local proj = fixture_project(ctx)
	local dest = ctx.path("home")
	bb.writef(ctx, "proj/w.lua", apply_workflow(dest, ", check = true"))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true", "check reports would-change")
	h.contains(r.stdout, "APPLY count changed=3", "would-change lines for all files")
	h.eq(ctx.exists("home/top.conf"), false, "nothing written")
	h.eq(ctx.exists("home/app"), false, "no directories created either")
	h.matches(h.norm(ctx, r.stderr), "changed: %[host%] <TMP>/home/top%.conf %(Ts%)",
		"would-change step lines on stderr")
	-- converged state + check = clean
	bb.writef(ctx, "proj/apply.lua", apply_workflow(dest))
	h.eq(ctx.run({ "run", "apply.lua" }, { chdir = proj }).code, 0, "real apply")
	local r2 = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r2.code, 0, "second check exit: " .. r2.stderr)
	h.contains(r2.stdout, "APPLY changed=false", "converged tree checks clean")
end)

h.case("apply", "files_escape_hatch_with_inline_content", function(ctx)
	local proj = bb.make_project(ctx, "proj")
	local d1, d2 = ctx.path("home/one.conf"), ctx.path("home/two.conf")
	bb.writef(ctx, "proj/w.lua", ([[
local r = step { uses = "dots:apply", name = "dots", with = {
  files = {
    { dest = %q, content = "one\n", mode = "0644" },
    { dest = %q, content = "two\n" },
  },
} }
print("APPLY changed=" .. tostring(r.changed))
print("APPLY count changed=" .. #r.out.changed)
]]):format(d1, d2))
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "exit: " .. r.stderr)
	h.contains(r.stdout, "APPLY changed=true")
	h.contains(r.stdout, "APPLY count changed=2")
	h.eq(ctx.read("home/one.conf"), "one\n")
	h.eq(ctx.read("home/two.conf"), "two\n")
	local st = makac.exec({ "stat", "-c", "%a", d1 })
	h.eq((st.stdout:gsub("%s+$", "")), "644", "mode honored on inline entries")
end)
