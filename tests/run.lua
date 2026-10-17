-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- Unit tests for the pure/host-side parts of makac.dots, driven by the makac
-- binary:  /home/nixos/repos/makac/zig-out/bin/makac tests/run.lua
-- (run from the package root; the project wires this package in place, so
-- "pkgs/dots/..." requires the lib/ modules directly).

local t = dofile(SCRIPT_DIR .. "/lib/t.lua")
local fake = dofile(SCRIPT_DIR .. "/lib/fake_target.lua")
local action_file = require("pkgs/dots/action_file")
local materialize = require("pkgs/dots/materialize")

-- the managed journal writes to makac.data_dir on every successful mutation;
-- point it at a throwaway dir for the whole run so unit cases journaling
-- against fake targets never touch this repo's own .makac/.
makac.data_dir = tostring(makac.fs.mktemp_dir("dots-unit-dd-"))

local function new_target(tag)
	return fake.new(tostring(makac.fs.mktemp_dir("dots-test-" .. tag .. "-")))
end

local function read(path)
	return makac.fs.read_file(path)
end

local function mode_of(path)
	local res = makac.exec({ "stat", "-c", "%a", "--", path })
	return (res.stdout or ""):gsub("%s+$", "")
end

-- ---------------------------------------------------------------- dots:file

t.case("content write to fresh dest", function()
	local tgt = new_target("content")
	local res = action_file.file({
		dest = "~/.config/foo/config",
		content = "hello = 1\n",
		target = tgt,
	})
	t.eq(res.err, nil, "no error")
	t.eq(res.changed, true, "first write changes")
	local path = tgt.root .. "/.config/foo/config"
	t.eq(res.out.path, path, "out.path is the expanded dest")
	t.eq(read(path), "hello = 1\n", "bytes on the target")
	t.eq(res.out.sha256, makac.sha256("hello = 1\n"), "out.sha256 is the desired bytes' hash")
end)

t.case("src write relative to a tree root", function()
	local tgt = new_target("src")
	local tree = tostring(makac.fs.mktemp_dir("dots-tree-"))
	makac.fs.write_file(tree .. "/bar.conf", "bar = true\n")
	local res = action_file.file({
		dest = "~/bar.conf",
		src = "bar.conf",
		root = tree,
		target = tgt,
	})
	t.eq(res.err, nil, "no error")
	t.eq(res.changed, true)
	t.eq(read(tgt.root .. "/bar.conf"), "bar = true\n")
end)

t.case("renderer is applied and its output hashed", function()
	local tgt = new_target("renderer")
	local res = action_file.file({
		dest = "~/up.txt",
		content = "hello",
		renderer = function(content) return (content:upper()) end,
		target = tgt,
	})
	t.eq(res.err, nil)
	t.eq(read(tgt.root .. "/up.txt"), "HELLO")
	t.eq(res.out.sha256, makac.sha256("HELLO"), "rendered output is what gets hashed")
end)

t.case("second run is a no-op (changed = false)", function()
	local tgt = new_target("noop")
	local with = { dest = "~/a", content = "same", target = tgt }
	local first = action_file.file(with)
	t.eq(first.changed, true)
	local second = action_file.file(with)
	t.eq(second.err, nil)
	t.eq(second.changed, false, "identical file is a successful no-op")
	t.eq(second.out.sha256, makac.sha256("same"))
end)

t.case("drift with override = true restores the file", function()
	local tgt = new_target("drift")
	local with = { dest = "~/b", content = "managed", override = true, target = tgt }
	t.eq(action_file.file(with).changed, true)
	makac.fs.write_file(tgt.root .. "/b", "drifted")
	local res = action_file.file(with)
	t.eq(res.err, nil)
	t.eq(res.changed, true, "drift counts as a change")
	t.eq(read(tgt.root .. "/b"), "managed", "drift is restored")
end)

t.case("conflict: differing file + override = false errors, file untouched", function()
	local tgt = new_target("conflict")
	makac.fs.write_file(tgt.root .. "/c", "pre-existing")
	local res = action_file.file({ dest = "~/c", content = "managed", target = tgt })
	t.truthy(res.err, "err is set")
	t.contains(res.err, "conflict")
	t.eq(read(tgt.root .. "/c"), "pre-existing", "the file is left untouched")
end)

t.case("override = true replaces a differing file", function()
	local tgt = new_target("override")
	makac.fs.write_file(tgt.root .. "/d", "pre-existing")
	local res = action_file.file({
		dest = "~/d", content = "managed", override = true, target = tgt,
	})
	t.eq(res.err, nil)
	t.eq(res.changed, true)
	t.eq(read(tgt.root .. "/d"), "managed")
end)

t.case("mode is applied on write and repaired on drift", function()
	local tgt = new_target("mode")
	local with = { dest = "~/e", content = "x", mode = "0644", target = tgt }
	local res = action_file.file(with)
	t.eq(res.err, nil)
	t.eq(mode_of(tgt.root .. "/e"), "644", "0644 applied on write")
	makac.exec({ "chmod", "0600", tgt.root .. "/e" })
	local res2 = action_file.file(with)
	t.eq(res2.err, nil)
	t.eq(res2.changed, true, "mode drift alone counts as changed")
	t.eq(mode_of(tgt.root .. "/e"), "644", "mode drift is repaired")
	local res3 = action_file.file(with)
	t.eq(res3.changed, false, "content+mode identical: no change")
end)

t.case("owner is applied when specified", function()
	local tgt = new_target("owner")
	local user = (makac.exec({ "id", "-un" }).stdout):gsub("%s+$", "")
	local group = (makac.exec({ "id", "-gn" }).stdout):gsub("%s+$", "")
	local with = { dest = "~/f", content = "y", owner = user .. ":" .. group, target = tgt }
	local res = action_file.file(with)
	t.eq(res.err, nil, "chown to self works")
	local res2 = action_file.file(with)
	t.eq(res2.err, nil)
	t.eq(res2.changed, false, "owner already correct: no change")
end)

t.case("absent removes, is idempotent, and refuses directories", function()
	local tgt = new_target("absent")
	makac.fs.write_file(tgt.root .. "/gone", "x")
	local res = action_file.file({ dest = "~/gone", absent = true, target = tgt })
	t.eq(res.err, nil)
	t.eq(res.changed, true, "removal is a change")
	t.eq(makac.fs.stat(tgt.root .. "/gone"), nil, "file is gone")
	local res2 = action_file.file({ dest = "~/gone", absent = true, target = tgt })
	t.eq(res2.changed, false, "already absent: no change")
	-- directories are never removed
	makac.fs.mkdir_p(tgt.root .. "/subdir")
	local res3 = action_file.file({ dest = "~/subdir", absent = true, target = tgt })
	t.truthy(res3.err, "directory refusal sets err")
	t.truthy(makac.fs.stat(tgt.root .. "/subdir") ~= nil, "directory is untouched")
end)

t.case("skip never manages the file", function()
	local tgt = new_target("skip")
	local res = action_file.file({ dest = "~/s", content = "x", skip = true, target = tgt })
	t.eq(res.skipped, true)
	t.eq(res.changed, nil)
	t.eq(makac.fs.stat(tgt.root .. "/s"), nil, "nothing was written")
end)

t.case("a link entry is an error in dots:file", function()
	local tgt = new_target("link")
	local res = action_file.file({ dest = "~/l", link = "/abs/target", target = tgt })
	t.contains(res.err or "", "dots:link")
end)

t.case("materialize over a directory is refused", function()
	local tgt = new_target("dirrefusal")
	makac.fs.mkdir_p(tgt.root .. "/dirdest")
	local res = action_file.file({ dest = "~/dirdest", content = "x", target = tgt })
	t.truthy(res.err, "err is set")
	t.truthy(makac.fs.stat(tgt.root .. "/dirdest") ~= nil, "directory is untouched")
end)

t.case("an existing symlink differs from a file entry", function()
	local tgt = new_target("symlink")
	makac.fs.write_file(tgt.root .. "/real", "managed")
	makac.fs.symlink(tgt.root .. "/real", tgt.root .. "/lnk")
	local res = action_file.file({ dest = "~/lnk", content = "managed", target = tgt })
	t.truthy(res.err, "conflict without override")
	local res2 = action_file.file({
		dest = "~/lnk", content = "managed", override = true, target = tgt,
	})
	t.eq(res2.err, nil)
	t.eq(res2.changed, true)
	t.eq(makac.fs.stat(tgt.root .. "/lnk").type, "file", "symlink replaced by a real file")
end)

-- ---------------------------------------------------------------- dots:link

local function link_target(path)
	local res = makac.exec({ "readlink", "--", path })
	if res.code ~= 0 then return nil end
	return (res.stdout or ""):gsub("%s+$", "")
end

t.case("link: create, idempotent re-run", function()
	local tgt = new_target("link-create")
	makac.fs.write_file(tgt.root .. "/real.conf", "content")
	-- store an absolute target string
	local with = { dest = "~/deep/dir/lnk", link = tgt.root .. "/real.conf", target = tgt }
	local res = action_file.link(with)
	t.eq(res.err, nil)
	t.eq(res.changed, true, "creation is a change")
	t.eq(res.out.path, tgt.root .. "/deep/dir/lnk", "out.path is the expanded dest")
	t.eq(link_target(tgt.root .. "/deep/dir/lnk"), tgt.root .. "/real.conf")
	t.eq(makac.fs.stat(tgt.root .. "/deep/dir/lnk").type, "link")
	local res2 = action_file.link(with)
	t.eq(res2.err, nil)
	t.eq(res2.changed, false, "already pointing at the right target: no-op")
end)

t.case("link: relative target string is stored verbatim", function()
	local tgt = new_target("link-rel")
	makac.fs.mkdir_p(tgt.root .. "/cfg")
	local res = action_file.link({ dest = "~/cfg/lnk", link = "../somewhere", target = tgt })
	t.eq(res.err, nil)
	t.eq(link_target(tgt.root .. "/cfg/lnk"), "../somewhere")
end)

t.case("link: symlink pointing elsewhere is a conflict; override replaces", function()
	local tgt = new_target("link-conflict")
	makac.fs.write_file(tgt.root .. "/a", "a")
	makac.fs.write_file(tgt.root .. "/b", "b")
	makac.fs.symlink(tgt.root .. "/a", tgt.root .. "/l")
	local with = { dest = "~/l", link = tgt.root .. "/b", target = tgt }
	local res = action_file.link(with)
	t.contains(res.err or "", "conflict", "wrong target without override errors")
	t.eq(link_target(tgt.root .. "/l"), tgt.root .. "/a", "left untouched")
	local res2 = action_file.link({
		dest = "~/l", link = tgt.root .. "/b", override = true, target = tgt,
	})
	t.eq(res2.err, nil)
	t.eq(res2.changed, true)
	t.eq(link_target(tgt.root .. "/l"), tgt.root .. "/b", "override replaces")
end)

t.case("link: a regular file/dir at dest is never replaced", function()
	local tgt = new_target("link-vs-file")
	makac.fs.write_file(tgt.root .. "/f", "real")
	local res = action_file.link({ dest = "~/f", link = "/abs/target", override = true, target = tgt })
	t.truthy(res.err, "conflict even with override")
	t.eq(read(tgt.root .. "/f"), "real", "file untouched")
	makac.fs.mkdir_p(tgt.root .. "/d")
	local res2 = action_file.link({ dest = "~/d", link = "/abs/target", override = true, target = tgt })
	t.truthy(res2.err, "directory also refused")
end)

t.case("link: absent removes only the link, idempotent, refuses real nodes", function()
	local tgt = new_target("link-absent")
	makac.fs.write_file(tgt.root .. "/real", "real")
	makac.fs.symlink(tgt.root .. "/real", tgt.root .. "/lnk")
	local res = action_file.link({ dest = "~/lnk", absent = true, target = tgt })
	t.eq(res.err, nil)
	t.eq(res.changed, true)
	t.eq(makac.fs.stat(tgt.root .. "/lnk"), nil, "link is gone")
	t.truthy(read(tgt.root .. "/real") ~= nil, "the link target is untouched")
	local res2 = action_file.link({ dest = "~/lnk", absent = true, target = tgt })
	t.eq(res2.changed, false, "already absent: no change")
	local res3 = action_file.link({ dest = "~/real", absent = true, target = tgt })
	t.truthy(res3.err, "refusing to remove a regular file")
	t.truthy(read(tgt.root .. "/real") ~= nil, "file untouched")
end)

t.case("link: mode/owner are rejected", function()
	local tgt = new_target("link-mode")
	local res = action_file.link({ dest = "~/m", link = "/x", mode = "0644", target = tgt })
	t.contains(res.err or "", "mode/owner")
	local res2 = action_file.link({ dest = "~/m", link = "/x", owner = "root:root", target = tgt })
	t.contains(res2.err or "", "mode/owner")
	t.eq(makac.fs.stat(tgt.root .. "/m"), nil, "nothing was written")
end)

t.case("link: skip never manages", function()
	local tgt = new_target("link-skip")
	local res = action_file.link({ dest = "~/s", link = "/x", skip = true, target = tgt })
	t.eq(res.skipped, true)
	t.eq(makac.fs.stat(tgt.root .. "/s"), nil, "nothing was written")
end)

-- ------------------------------------------------------------- materialize

t.case("expand: ~ and ~/ against the target's HOME", function()
	local tgt = new_target("expand")
	local home = materialize.target_home(tgt)
	t.eq(home, tgt.root)
	t.eq(materialize.expand(tgt, "~"), tgt.root)
	t.eq(materialize.expand(tgt, "~/a/b"), tgt.root .. "/a/b")
	t.eq(materialize.expand(tgt, "/abs/path"), "/abs/path", "absolute paths pass through")
	t.eq(materialize.expand(tgt, "rel/path"), "rel/path", "relative paths pass through")
end)

t.case("desired_bytes: content, src, renderer, errors", function()
	t.eq(materialize.desired_bytes({ content = "c" }), "c")
	local tree = tostring(makac.fs.mktemp_dir("dots-tree-"))
	makac.fs.write_file(tree .. "/f", "from-src")
	t.eq(materialize.desired_bytes({ src = "f" }, tree), "from-src")
	t.eq(materialize.desired_bytes({ src = tree .. "/f" }), "from-src", "absolute src needs no root")
	t.eq(
		materialize.desired_bytes({ content = "ab", renderer = function(c) return c .. c end }),
		"abab"
	)
	local v, err = materialize.desired_bytes({ src = "relative" })
	t.eq(v, nil)
	t.contains(err, "no tree root")
	local v2, err2 = materialize.desired_bytes({})
	t.eq(v2, nil)
	t.contains(err2, "neither")
	local v3, err3 = materialize.desired_bytes({
		content = "x", renderer = function() return 42 end,
	})
	t.eq(v3, nil)
	t.contains(err3, "must return a string")
end)

t.case("remote_kind: absent / file / dir / link", function()
	local tgt = new_target("kind")
	t.eq(materialize.remote_kind(tgt, tgt.root .. "/nope"), "absent")
	makac.fs.write_file(tgt.root .. "/f", "x")
	t.eq(materialize.remote_kind(tgt, tgt.root .. "/f"), "file")
	makac.fs.mkdir_p(tgt.root .. "/d")
	t.eq(materialize.remote_kind(tgt, tgt.root .. "/d"), "dir")
	makac.fs.symlink(tgt.root .. "/f", tgt.root .. "/l")
	t.eq(materialize.remote_kind(tgt, tgt.root .. "/l"), "link")
end)

t.case("remote_sha256 matches makac.sha256 of the bytes", function()
	local tgt = new_target("sha")
	makac.fs.write_file(tgt.root .. "/h", "hash me \0 with nul")
	t.eq(materialize.remote_sha256(tgt, tgt.root .. "/h"),
		makac.sha256("hash me \0 with nul"))
end)

t.case("mode_eq / owner_eq normalization", function()
	t.truthy(materialize.mode_eq("644", "0644"))
	t.truthy(materialize.mode_eq("0600", "600"))
	t.truthy(not materialize.mode_eq("644", "600"))
	t.truthy(materialize.owner_eq("jwd:jwd", "jwd:jwd"))
	t.truthy(materialize.owner_eq("jwd:jwd", "jwd"), "owner without group matches the user part")
	t.truthy(not materialize.owner_eq("jwd:root", "jwd:jwd"))
end)

-- -------------------------------------------------------------------- glob

local glob = require("pkgs/dots/glob")

t.case("glob: * within a segment, ** across, trailing / a subtree", function()
	t.truthy(glob.match("*.bak", "a.bak"))
	t.truthy(not glob.match("*.bak", "a.txt"))
	t.truthy(not glob.match("*.bak", "sub/a.bak"), "* never crosses /")
	t.truthy(glob.match("**/.DS_Store", "sub/.DS_Store"))
	t.truthy(glob.match("**/.DS_Store", "a/b/c/.DS_Store"))
	t.truthy(not glob.match("**/.DS_Store", "a/b/x.txt"))
	t.truthy(glob.match("foo*bar", "foobar"))
	t.truthy(not glob.match("foo*bar", "foo/bar"))
	t.truthy(glob.match("secrets/", "secrets"), "the directory itself")
	t.truthy(glob.match("secrets/", "secrets/a/b/c"), "everything under it")
	t.truthy(not glob.match("secrets/", "src/secrets"), "no partial-segment match")
	t.truthy(glob.match("*-local.conf", "foo-local.conf"))
	t.truthy(not glob.match("exact", "exactly"))
end)

-- -------------------------------------------------------------- plan: walk

local plan = require("pkgs/dots/plan")

local function new_tree(tag)
	return tostring(makac.fs.mktemp_dir("dots-tree-" .. tag .. "-"))
end

-- write file at path, creating parents
local function wf(path, data)
	local dir = path:match("^(.+)/[^/]+$")
	if dir then makac.fs.mkdir_p(dir) end
	makac.fs.write_file(path, data)
end

local function dests(entries)
	local out = {}
	for _, e in ipairs(entries) do out[#out + 1] = e.dest end
	return table.concat(out, ",")
end

local function by_dest(entries)
	local out = {}
	for _, e in ipairs(entries) do out[e.dest] = e end
	return out
end

t.case("tree: plain tree, dest/src and deterministic order", function()
	local root = new_tree("plain")
	wf(root .. "/z.txt", "z")
	wf(root .. "/a.txt", "a")
	wf(root .. "/m/b.txt", "b")
	wf(root .. "/a-dir/x.txt", "x")
	makac.fs.mkdir_p(root .. "/empty") -- empty dirs ship nothing
	local entries = plan.tree(root)
	t.eq(dests(entries), "~/a-dir/x.txt,~/a.txt,~/m/b.txt,~/z.txt",
		"depth-first, names sorted")
	local m = by_dest(entries)
	t.eq(m["~/a.txt"].src, "a.txt")
	t.eq(m["~/m/b.txt"].src, "m/b.txt")
	t.eq(m["~/z.txt"].override, false, "override defaults to false")
	local entries2 = plan.tree(root, { dest = "/etc/" })
	t.eq(by_dest(entries2)["/etc/a.txt"] ~= nil, true, "dest prefix, trailing / normalized")
end)

t.case("tree: $default applies to unlisted files only, never subdirs", function()
	local root = new_tree("default")
	wf(root .. "/dots.lua", [[
return {
	["$default"] = { mode = "0600" },
	["listed.conf"] = { mode = "0644", owner = "root:root" },
}]])
	wf(root .. "/listed.conf", "l")
	wf(root .. "/unlisted.conf", "u")
	wf(root .. "/sub/inner.conf", "i")
	local m = by_dest(plan.tree(root))
	t.eq(m["~/listed.conf"].mode, "0644", "explicit entry wins")
	t.eq(m["~/listed.conf"].owner, "root:root")
	t.eq(m["~/unlisted.conf"].mode, "0600", "$default fills the gap")
	t.eq(m["~/sub/inner.conf"].mode, nil, "$default is strictly directory-local")
end)

t.case("tree: $default with absent/skip/override is an error", function()
	for _, key in ipairs({ "absent", "skip", "override" }) do
		local root = new_tree("baddefault")
		wf(root .. "/dots.lua", ("return { ['$default'] = { %s = true } }"):format(key))
		wf(root .. "/f", "f")
		local ok, err = pcall(plan.tree, root)
		t.truthy(not ok, "$default with " .. key .. " must fail")
		t.contains(tostring(err), "$default")
	end
end)

t.case("tree: $ignore files and dirs, ** across segments", function()
	local root = new_tree("ignore")
	wf(root .. "/dots.lua", [[
return { ["$ignore"] = { "*.bak", "secrets/", "**/.DS_Store" } }]])
	wf(root .. "/keep.conf", "k")
	wf(root .. "/drop.bak", "d")
	wf(root .. "/secrets/password.txt", "p")
	wf(root .. "/sub/x.conf", "x")
	wf(root .. "/sub/.DS_Store", "junk")
	wf(root .. "/sub/deep/.DS_Store", "junk")
	local entries = plan.tree(root)
	t.eq(dests(entries), "~/keep.conf,~/sub/x.conf")
end)

t.case("tree: .git, .makac, dots.lua are auto-ignored everywhere", function()
	local root = new_tree("autoignore")
	wf(root .. "/.git/config", "g")
	wf(root .. "/.makac/dots/host", "m")
	wf(root .. "/dots.lua", "return {}")
	wf(root .. "/sub/dots.lua", "return {}")
	wf(root .. "/sub/.git/x", "g")
	wf(root .. "/real.conf", "r")
	-- only real.conf; sub's dots.lua is reserved, sub/.git dropped
	t.eq(dests(plan.tree(root)), "~/real.conf")
end)

t.case("tree: nested sidecars are independent", function()
	local root = new_tree("nested")
	wf(root .. "/dots.lua", [[
return { ["$default"] = { mode = "0644" } }]])
	wf(root .. "/sub/dots.lua", [[
return { ["$default"] = { mode = "0600" }, ["$ignore"] = { "tmp/" } }]])
	wf(root .. "/top.conf", "t")
	wf(root .. "/sub/inner.conf", "i")
	wf(root .. "/sub/tmp/scratch", "s")
	wf(root .. "/sub/tmp/deep/more", "m")
	local m = by_dest(plan.tree(root))
	t.eq(m["~/top.conf"].mode, "0644")
	t.eq(m["~/sub/inner.conf"].mode, "0600", "nested $default governs its own dir")
	t.truthy(m["~/sub/tmp/scratch"] == nil, "nested $ignore not descended into")
	t.truthy(m["~/sub/tmp/deep/more"] == nil)
end)

t.case("tree: override precedence entry > $override > call-site > false", function()
	local root = new_tree("override")
	wf(root .. "/dots.lua", [[
return {
	["$override"] = function(name) return name:match("%.local$") ~= nil end,
	["foo.conf"] = { override = true },
	["bar.local"] = { override = false },
}]])
	wf(root .. "/foo.conf", "f")
	wf(root .. "/bar.local", "b")
	wf(root .. "/baz.local", "z")
	wf(root .. "/plain.conf", "p")
	-- no call-site override
	local m = by_dest(plan.tree(root))
	t.eq(m["~/foo.conf"].override, true, "per-entry wins over the predicate")
	t.eq(m["~/bar.local"].override, false, "per-entry false wins over the predicate")
	t.eq(m["~/baz.local"].override, true, "$override function selected")
	t.eq(m["~/plain.conf"].override, false, "$override function rejected")
	-- call-site true: the sidecar still wins
	local m2 = by_dest(plan.tree(root, { override = true }))
	t.eq(m2["~/plain.conf"].override, false)
	t.eq(m2["~/foo.conf"].override, true)
	-- a sidecar-less tree takes the call-site value
	local root2 = new_tree("override-callsite")
	wf(root2 .. "/x.conf", "x")
	t.eq(plan.tree(root2, { override = true })[1].override, true, "call-site default when no sidecar")
	t.eq(plan.tree(root2)[1].override, false, "false when nothing says otherwise")
	-- boolean $override
	local root3 = new_tree("override-bool")
	wf(root3 .. "/dots.lua", "return { ['$override'] = true }")
	wf(root3 .. "/y.conf", "y")
	t.eq(plan.tree(root3)[1].override, true, "plain boolean $override")
end)

t.case("tree: renderer captured from a sidecar entry", function()
	local root = new_tree("renderer")
	wf(root .. "/dots.lua", [[
return { ["r.conf"] = { renderer = function(c) return c:upper() end } }]])
	wf(root .. "/r.conf", "r")
	local e = plan.tree(root)[1]
	t.eq(type(e.renderer), "function")
	t.eq(e.renderer("abc"), "ABC")
end)

t.case("tree: source symlinks", function()
	local root = new_tree("symlink")
	wf(root .. "/real.txt", "content")
	makac.fs.symlink("real.txt", root .. "/via-link.txt")
	-- default: dereference — a regular materialize entry
	local m = by_dest(plan.tree(root))
	t.eq(m["~/via-link.txt"].src, "via-link.txt", "read through the link")
	t.eq(m["~/via-link.txt"].link, nil)
	-- reproduce: becomes a link entry carrying the stored target string
	wf(root .. "/dots.lua", [[
return { ["via-link.txt"] = { reproduce = true } }]])
	local m2 = by_dest(plan.tree(root))
	t.eq(m2["~/via-link.txt"].link, "real.txt", "symlink recreated as given")
	t.eq(m2["~/via-link.txt"].src, nil)
	-- broken symlink in dereference mode: a loud walk error
	local root2 = new_tree("broken")
	makac.fs.symlink("missing-target", root2 .. "/dangling")
	local ok, err = pcall(plan.tree, root2)
	t.truthy(not ok, "broken symlink fails the walk")
	t.contains(tostring(err), "dangling")
	-- ... unless reproduce = true
	wf(root2 .. "/dots.lua", [[
return { ["dangling"] = { reproduce = true } }]])
	local m3 = by_dest(plan.tree(root2))
	t.eq(m3["~/dangling"].link, "missing-target")
end)

t.case("tree: load_sidecar, and sidecar using PROJECT_DIR", function()
	local root = new_tree("sidecarload")
	t.eq(plan.load_sidecar(root), nil, "nil when absent")
	wf(root .. "/shared.lua", "return { mode = '0600' }")
	wf(root .. "/dots.lua", [[
local d = dofile(PROJECT_DIR .. "/shared-in-project.lua")
return { ["$default"] = d }]])
	wf(root .. "/f.conf", "f")
	-- PROJECT_DIR is the makac.dots project root when tests run under it
	makac.fs.write_file(tostring(PROJECT_DIR) .. "/shared-in-project.lua", "return { mode = '0600' }")
	local m = by_dest(plan.tree(root))
	t.eq(m["~/f.conf"].mode, "0600", "sidecar composed via dofile(PROJECT_DIR .. ...)")
	makac.exec({ "rm", "-f", tostring(PROJECT_DIR) .. "/shared-in-project.lua" })
	-- a broken sidecar is a loud error, not a skip
	wf(root .. "/dots.lua", "this is not lua")
	local ok, err = pcall(plan.load_sidecar, root)
	t.truthy(not ok)
	t.contains(tostring(err), "dots.lua")
end)

-- ---------------------------------------------------------------- dots:apply

local action_apply = require("pkgs/dots/action_apply")

local function read_in(tgt, rel)
	return makac.fs.read_file(tgt.root .. "/" .. rel)
end

t.case("apply: 3-file tree, first run changed, second all ok", function()
	local root = new_tree("apply3")
	wf(root .. "/a.conf", "aaa")
	wf(root .. "/sub/b.conf", "bbb")
	wf(root .. "/sub/deep/c.conf", "ccc")
	local tgt = new_target("apply3")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true, "first run changed")
	t.eq(#r.out.changed, 3)
	t.eq(#r.out.failed, 0)
	t.eq(read_in(tgt, "a.conf"), "aaa")
	t.eq(read_in(tgt, "sub/b.conf"), "bbb")
	t.eq(read_in(tgt, "sub/deep/c.conf"), "ccc")
	-- idempotent: second run is all ok
	local r2 = action_apply.apply({ root = root, target = tgt })
	t.eq(r2.err, nil)
	t.eq(r2.changed, false, "second run unchanged")
	t.eq(#r2.out.ok, 3)
	t.eq(#r2.out.changed, 0)
end)

t.case("apply: one conflict does not stop the loop, err stays unset", function()
	local root = new_tree("applyconflict")
	wf(root .. "/first.conf", "one")
	wf(root .. "/conflicted.conf", "desired")
	wf(root .. "/last.conf", "three")
	local tgt = new_target("applyconflict")
	makac.fs.write_file(tgt.root .. "/conflicted.conf", "local edit")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil, "per-file failure is data, never err")
	t.eq(r.changed, true, "the other files changed")
	t.eq(#r.out.failed, 1)
	t.eq(r.out.failed[1].path, "~/conflicted.conf")
	t.contains(r.out.failed[1].err, "conflict")
	t.eq(read_in(tgt, "conflicted.conf"), "local edit", "loser left untouched")
	t.eq(read_in(tgt, "first.conf"), "one")
	-- the loop CONTINUED past the failure into the entry after it:
	t.eq(read_in(tgt, "last.conf"), "three", "entries after the failure still applied")
end)

t.case("apply: strict=true turns failures into err", function()
	local root = new_tree("applystrict")
	wf(root .. "/a.conf", "a")
	wf(root .. "/b.conf", "b")
	local tgt = new_target("applystrict")
	makac.fs.write_file(tgt.root .. "/a.conf", "differing")
	local r = action_apply.apply({ root = root, target = tgt, strict = true })
	t.truthy(r.err ~= nil, "strict aborts")
	t.contains(r.err, "strict")
	t.eq(read_in(tgt, "b.conf"), "b", "non-failing entries still applied before err")
	-- ... and the strict shape is what makes `step{uses="dots:apply"}` abort
	local sok = pcall(step, { uses = "dots:apply", name = "strict-apply",
		with = { root = root, target = tgt, strict = true } })
	t.eq(sok, false, "step() raises on the strict err")
	-- without strict the same run through step() succeeds
	local sok2, r2 = pcall(step, { uses = "dots:apply", name = "lenient-apply",
		with = { root = root, target = tgt } })
	t.eq(sok2, true, "step() succeeds with err unset")
	t.eq(#r2.out.failed, 1)
end)

t.case("apply: files= escape hatch", function()
	local tgt = new_target("applyfiles")
	makac.fs.write_file(tgt.root .. "/gone.conf", "stale")
	local r = action_apply.apply({
		target = tgt,
		files = {
			{ dest = "~/inline.conf", content = "inline" },
			{ dest = "~/gone.conf", absent = true },
		},
	})
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(#r.out.changed, 2)
	t.eq(read_in(tgt, "inline.conf"), "inline")
	t.eq(read_in(tgt, "gone.conf"), nil, "absent removed it")
end)

t.case("apply: check=true reports without writing", function()
	local root = new_tree("applycheck")
	wf(root .. "/a.conf", "aaa")
	wf(root .. "/b.conf", "bbb")
	local tgt = new_target("applycheck")
	local r = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r.err, nil)
	t.eq(r.changed, true, "would change")
	t.eq(#r.out.changed, 2)
	t.eq(read_in(tgt, "a.conf"), nil, "nothing written")
	t.eq(read_in(tgt, "b.conf"), nil)
	-- real apply, then a re-check is clean
	action_apply.apply({ root = root, target = tgt })
	local r2 = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r2.changed, false)
	-- check still counts a conflict as a failure (state cannot converge)
	makac.fs.write_file(tgt.root .. "/a.conf", "local edit")
	local r3 = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r3.err, nil)
	t.eq(#r3.out.failed, 1)
	t.eq(read_in(tgt, "a.conf"), "local edit", "check wrote nothing")
end)

t.case("apply: link entries route to dots:link", function()
	local root = new_tree("applylink")
	wf(root .. "/dots.lua", [[
return { ["linked"] = { link = "../elsewhere/target" } }]])
	wf(root .. "/linked", "ignored bytes")
	wf(root .. "/plain.conf", "p")
	local tgt = new_target("applylink")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(makac.fs.stat(tgt.root .. "/linked").type, "link", "a symlink was made")
	t.eq(read_in(tgt, "plain.conf"), "p")
end)

t.case("apply: requires root or files", function()
	local r = action_apply.apply({})
	t.truthy(r.err ~= nil)
	t.contains(r.err, "root")
end)

-- ---------------------------------------------------------------- journal

local journal = require("pkgs/dots/journal")

t.case("journal: update dedupes, sorts, rewrites wholesale", function()
	local dd = tostring(makac.fs.mktemp_dir("dots-journal-"))
	t.eq(#journal.list(dd, "host"), 0, "no journal yet")
	journal.update(dd, "host", { "/b", "/a" })
	local got = journal.list(dd, "host")
	t.eq(#got, 2)
	t.eq(got[1], "/a", "sorted")
	t.eq(got[2], "/b")
	-- second update unions and dedupes
	journal.update(dd, "host", { "/b", "/c" })
	got = journal.list(dd, "host")
	t.eq(#got, 3, "union with dedupe")
	t.eq(got[3], "/c")
	-- the file itself is newline-separated, sorted
	local body = makac.fs.read_file(journal.file_path(dd, "host"))
	t.eq(body, "/a\n/b\n/c\n", "wholesale sorted newline format")
	-- targets are keyed independently
	t.eq(#journal.list(dd, "workpc"), 0, "other target unaffected")
	journal.update(dd, "workpc", { "/r1" })
	t.eq(#journal.list(dd, "host"), 3, "host journal untouched")
	t.eq(journal.list(dd, "workpc")[1], "/r1")
	-- non-absolute paths are rejected
	t.eq(select(2, pcall(journal.update, dd, "host", { "rel/x" })) ~= nil, true,
		"relative path rejected")
end)

t.case("journal: dots:file records writes; check mode does not", function()
	-- hook behavior against the run-wide throwaway data dir
	local dd = makac.data_dir
	local tgt = new_target("journalhook")
	local jname = tostring(tgt.name)
	local dest = tgt.root .. "/jx.conf"
	-- a write journals the expanded path
	local r = action_file.file({ dest = dest, content = "x\n", target = tgt })
	t.eq(r.err, nil)
	local got = journal.list(dd, jname)
	t.eq(#got, 1)
	t.eq(got[1], dest, "expanded dest recorded")
	-- a no-change rerun adds nothing
	action_file.file({ dest = dest, content = "x\n", target = tgt })
	t.eq(#journal.list(dd, jname), 1, "rerun dedupes")
	-- check mode reports a change but does NOT journal
	local r2 = action_file.file({ dest = tgt.root .. "/jy.conf", content = "y\n",
		target = tgt, check = true })
	t.eq(r2.changed, true, "check reports would-change")
	t.eq(#journal.list(dd, jname), 1, "check mode writes no journal")
	-- failures journal nothing
	local r3 = action_file.file({ dest = tgt.root .. "/jz.conf",
		target = tgt }) -- no src/content/absent: invalid
	t.truthy(r3.err ~= nil)
	t.eq(#journal.list(dd, jname), 1, "failures not recorded")
	-- absent-removal records the removed path (design: removals are
	-- journaled too — 'paths this package has written')
	local r4 = action_file.file({ dest = dest, absent = true, target = tgt })
	t.eq(r4.err, nil)
	t.eq(r4.changed, true)
	t.eq(#journal.list(dd, jname), 1, "remove re-records the same path")
	-- dots:link records too
	local ldest = tgt.root .. "/jx.link"
	local r5 = action_file.link({ dest = ldest, link = dest, target = tgt })
	t.eq(r5.err, nil)
	local got2 = journal.list(dd, jname)
	t.eq(#got2, 2)
	t.eq(got2[2], ldest, "symlink recorded")
end)

t.done()
