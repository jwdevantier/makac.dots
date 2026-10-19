-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- Unit tests for the pure/host-side parts of makac.dots, driven by the makac
-- binary:  /home/nixos/repos/makac/zig-out/bin/makac tests/run.lua
-- (run from the package root; the project wires this package in place, so
-- "pkgs/dots/..." requires the lib/ modules directly).

local t = dofile(SCRIPT_DIR .. "/lib/t.lua")
local fake = dofile(SCRIPT_DIR .. "/lib/fake_target.lua")
local txtar = dofile(SCRIPT_DIR .. "/lib/txtar.lua")
local action_file = require("pkgs/dots/action_file")
local action_apply = require("pkgs/dots/action_apply")
local materialize = require("pkgs/dots/materialize")

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

-- ------------------------------------------------------------------ txtar

t.case("txtar: comment, file order, trailing newlines", function()
	local a = txtar.parse([[this describes the tree
over two lines
-- a.txt --
hello
-- sub/b.txt --
world
]])
	t.eq(a.comment, "this describes the tree\nover two lines\n")
	t.eq(#a.files, 2)
	t.eq(a.files[1].name, "a.txt")
	t.eq(a.files[1].data, "hello\n", "newline before next marker is part of the data")
	t.eq(a.files[2].name, "sub/b.txt")
	t.eq(a.files[2].data, "world\n")
end)

t.case("txtar: no trailing newline at EOF stays that way", function()
	local a = txtar.parse("-- a --\nno-eol")
	t.eq(a.files[1].data, "no-eol")
	-- an empty file: marker line immediately at EOF
	local b = txtar.parse("-- empty --\n")
	t.eq(b.files[1].data, "")
end)

t.case("txtar: indented literals are dedented, deeper indent kept", function()
	local a = txtar.parse([[-- dots.lua --
	return {
		["$ignore"] = { "*.tmp" },
	}
]])
	-- the Lua literal above is flush-left here, so parse it again indented
	local indented = a.files[1].data:gsub("\n", "\n\t\t")
	local b = txtar.parse("\t\t-- dots.lua --\n\t\t" .. indented)
	t.eq(b.files[1].data, a.files[1].data, "base indent stripped, relative indent preserved")
end)

t.case("txtar: no markers means everything is comment", function()
	local a = txtar.parse("just a note\nnothing else\n")
	t.eq(#a.files, 0)
	t.eq(a.comment, "just a note\nnothing else\n")
end)

t.case("txtar: unpack writes the tree into a temp dir", function()
	local dir = txtar.unpack([[a small nested fixture
-- app.conf --
key = value
-- ssh/config --
Host *
-- sub/real.conf --
real = true
]])
	t.eq(read(dir .. "/app.conf"), "key = value\n")
	t.eq(read(dir .. "/ssh/config"), "Host *\n")
	t.eq(read(dir .. "/sub/real.conf"), "real = true\n", "parents are created")
end)

t.case("txtar: unpack into a caller-provided dir", function()
	local dir = tostring(makac.fs.mktemp_dir("dots-txtar-into-"))
	local got = txtar.unpack("-- a --\nx\n", dir)
	t.eq(got, dir)
	t.eq(read(dir .. "/a"), "x\n")
end)

t.case("txtar: unpack rejects unsafe and duplicate names", function()
	for _, bad in ipairs({ "../x", "a/../../x", "/abs", "a//b", "trailing/", " padded" }) do
		local ok, err = pcall(txtar.unpack, "-- " .. bad .. " --\nx\n")
		t.truthy(not ok, "rejects " .. bad)
		t.contains(tostring(err), "txtar.unpack")
	end
	local ok, err = pcall(txtar.unpack, "-- a --\n1\n-- a --\n2\n")
	t.truthy(not ok, "rejects duplicates")
	t.contains(tostring(err), "duplicate")
end)

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

-- ------------------------------------------- directory creation (mkdir -p)
--
-- Both write paths run mkdir_parents before touching dest (a write is
-- mkdir -p of the parent, then temp-then-move; a link is mkdir -p of the
-- parent, then ln -s). These cases pin the
-- directory-creation behavior itself: depth, partial state, blockers,
-- symlinked intermediates, and that non-writing paths create nothing.

-- host-side kind of a node inside a fake target (fs.stat speaks the same
-- vocabulary as remote_kind; nil becomes "absent")
local function node_type(path)
	local st = makac.fs.stat(path)
	return st and st.type or "absent"
end

t.case("dirs: deep fresh nesting materializes every level", function()
	local tgt = new_target("deepfresh")
	local with = {
		dest = "~/.config/app/plugins/theme/theme.toml",
		content = "[theme]\n",
		target = tgt,
	}
	local res = action_file.file(with)
	t.eq(res.err, nil)
	t.eq(res.changed, true)
	t.eq(read(tgt.root .. "/.config/app/plugins/theme/theme.toml"), "[theme]\n")
	for _, d in ipairs({
		"/.config", "/.config/app", "/.config/app/plugins", "/.config/app/plugins/theme",
	}) do
		t.eq(node_type(tgt.root .. d), "dir", "intermediate is a directory: " .. d)
	end
	-- mkdir -p over the now-existing dirs is a no-op
	local res2 = action_file.file(with)
	t.eq(res2.err, nil)
	t.eq(res2.changed, false, "second run is a no-op")
end)

t.case("dirs: partially existing intermediates are kept and extended", function()
	local tgt = new_target("deeppartial")
	makac.fs.mkdir_p(tgt.root .. "/.config/app")
	makac.fs.write_file(tgt.root .. "/.config/other.conf", "keep me\n")
	local res = action_file.file({
		dest = "~/.config/app/plugins/p.conf",
		content = "p\n",
		target = tgt,
	})
	t.eq(res.err, nil)
	t.eq(read(tgt.root .. "/.config/app/plugins/p.conf"), "p\n")
	t.eq(read(tgt.root .. "/.config/other.conf"), "keep me\n", "existing content preserved")
end)

t.case("dirs: a file blocking an intermediate component is a clean error", function()
	local tgt = new_target("deepblocked")
	-- ~/.config exists as a regular FILE; txtar seeds the target state
	txtar.unpack("-- .config --\nnot a directory\n", tgt.root)
	local res = action_file.file({
		dest = "~/.config/foo/config",
		content = "managed\n",
		target = tgt,
	})
	t.truthy(res.err, "err is set")
	t.contains(res.err, "mkdir")
	t.eq(res.changed, nil, "a failed step reports no change")
	t.eq(read(tgt.root .. "/.config"), "not a directory\n", "the blocker is untouched")
	t.eq(#makac.fs.listdir(tgt.root), 1, "mkdir failed before write_file: no dirs, no temp detritus")
end)

t.case("dirs: a symlinked intermediate directory is followed", function()
	local tgt = new_target("symlinkparent")
	-- the classic stow-style setup: ~/.config is a symlink elsewhere
	makac.fs.mkdir_p(tgt.root .. "/real-config")
	makac.fs.symlink("real-config", tgt.root .. "/.config")
	local with = {
		dest = "~/.config/foo/config",
		content = "through the link\n",
		target = tgt,
	}
	local res = action_file.file(with)
	t.eq(res.err, nil)
	t.eq(res.changed, true)
	t.eq(read(tgt.root .. "/real-config/foo/config"), "through the link\n", "bytes landed through the link")
	t.eq(node_type(tgt.root .. "/.config"), "link", "the symlink itself is untouched")
	local res2 = action_file.file(with)
	t.eq(res2.err, nil)
	t.eq(res2.changed, false, "the no-op path works through the link too")
end)

t.case("dirs: dots:link creates deep parents too", function()
	local tgt = new_target("deeplink")
	local res = action_file.link({
		dest = "~/.local/share/app/current/link",
		link = "../v1",
		target = tgt,
	})
	t.eq(res.err, nil)
	t.eq(res.changed, true)
	t.eq(node_type(tgt.root .. "/.local/share/app/current/link"), "link")
	local cur, lerr = materialize.readlink(tgt, tgt.root .. "/.local/share/app/current/link")
	t.eq(lerr, nil)
	t.eq(cur, "../v1", "relative target stored verbatim")
end)

t.case("dirs: check=true creates neither directories nor the file", function()
	local tgt = new_target("deepcheck")
	local res = action_file.file({
		dest = "~/a/b/c/file",
		content = "x\n",
		check = true,
		target = tgt,
	})
	t.eq(res.err, nil)
	t.eq(res.changed, true, "reports it would change")
	t.eq(#makac.fs.listdir(tgt.root), 0, "nothing was created on the target")
end)

t.case("dirs: absent and skip never create directories", function()
	local tgt = new_target("deepabsent")
	local res = action_file.file({ dest = "~/a/b/file", absent = true, target = tgt })
	t.eq(res.err, nil)
	t.eq(res.changed, false, "a missing entry is already in the desired state")
	local res2 = action_file.file({ dest = "~/c/d/file", skip = true, target = tgt })
	t.eq(res2.skipped, true)
	local res3 = action_file.link({ dest = "~/e/f/link", absent = true, target = tgt })
	t.eq(res3.err, nil)
	t.eq(res3.changed, false)
	t.eq(#makac.fs.listdir(tgt.root), 0, "target untouched throughout")
end)

t.case("dirs: apply over a tree with a shared missing prefix", function()
	local root = txtar.unpack([[tree with one shared prefix, two branches
-- wm/i3/config --
set $mod Mod4
-- wm/i3/status.toml --
[status]
-- wm/polybar/config.ini --
[bar/top]
-- editor/init.lua --
vim = true
]])
	local tgt = new_target("applydirs")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(#r.out.changed, 4)
	t.eq(#r.out.failed, 0)
	t.eq(read(tgt.root .. "/wm/i3/config"), "set $mod Mod4\n")
	t.eq(read(tgt.root .. "/wm/polybar/config.ini"), "[bar/top]\n")
	t.eq(read(tgt.root .. "/editor/init.lua"), "vim = true\n")
	t.eq(node_type(tgt.root .. "/wm"), "dir")
	t.eq(node_type(tgt.root .. "/wm/i3"), "dir")
	t.eq(node_type(tgt.root .. "/wm/polybar"), "dir")
	-- the only thing at DEST besides the tree's dirs is the .makac store
	local names = {}
	for _, item in ipairs(makac.fs.listdir(tgt.root)) do names[item.name] = true end
	t.eq(names["wm"], true)
	t.eq(names["editor"], true)
	t.eq(names[".makac"], true, "the on-target snapshot store")
	local n = 0
	for _ in pairs(names) do n = n + 1 end
	t.eq(n, 3, "exactly the tree's two top-level dirs + the store, nothing stray")
	local r2 = action_apply.apply({ root = root, target = tgt })
	t.eq(r2.err, nil)
	t.eq(r2.changed, false)
	t.eq(#r2.out.ok, 4)
end)

-- ------------------------------------------------------------- materialize

t.case("resolve: ~, ~/ and absolute accepted", function()
	local tgt = new_target("resolve")
	local home = materialize.target_home(tgt)
	t.eq(home, tgt.root)
	t.eq(materialize.resolve(tgt, "~"), tgt.root)
	t.eq(materialize.resolve(tgt, "~/a/b"), tgt.root .. "/a/b")
	t.eq(materialize.resolve(tgt, "/abs/path"), "/abs/path", "absolute paths pass through")
end)

t.case("resolve: relative, ~user and '..' are rejected", function()
	local tgt = new_target("resolvebad")
	local v, err = materialize.resolve(tgt, "rel/path")
	t.eq(v, nil)
	t.contains(err, "relative")
	local v2, err2 = materialize.resolve(tgt, "~root/x")
	t.eq(v2, nil)
	t.contains(err2, "not supported")
	for _, bad in ipairs({ "~/../x", "/a/../b", "a/../b" }) do
		local v3, err3 = materialize.resolve(tgt, bad)
		t.eq(v3, nil, "rejects " .. bad)
		t.contains(err3, "'..'")
	end
end)

t.case("resolve: both verbs refuse a relative dest before touching the target", function()
	local tgt = new_target("resolveverb")
	local rf = action_file.file({ dest = "rel/f", content = "x", target = tgt })
	t.truthy(rf.err, "dots:file errs")
	t.contains(rf.err, "relative")
	local rl = action_file.link({ dest = "rel/l", link = "/x", target = tgt })
	t.truthy(rl.err, "dots:link errs")
	t.contains(rl.err, "relative")
	t.eq(#makac.fs.listdir(tgt.root), 0, "nothing was created")
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
	local root = txtar.unpack([[-- z.txt --
z
-- a.txt --
a
-- m/b.txt --
b
-- a-dir/x.txt --
x
]])
	makac.fs.mkdir_p(root .. "/empty") -- empty dirs ship nothing (txtar cannot express one)
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

t.case("tree: $default_attrs applies to unlisted files only, never subdirs", function()
	local root = txtar.unpack([[explicit entry wins; $default_attrs fills gaps, never reaches subdirs
-- dots.lua --
return {
	["$default_attrs"] = { mode = "0600" },
	["listed.conf"] = { mode = "0644", owner = "root:root" },
}
-- listed.conf --
l
-- unlisted.conf --
u
-- sub/inner.conf --
i
]])
	local m = by_dest(plan.tree(root))
	t.eq(m["~/listed.conf"].mode, "0644", "explicit entry wins")
	t.eq(m["~/listed.conf"].owner, "root:root")
	t.eq(m["~/unlisted.conf"].mode, "0600", "$default_attrs fills the gap")
	t.eq(m["~/sub/inner.conf"].mode, nil, "$default_attrs is strictly directory-local")
end)

t.case("tree: $default_attrs with absent/skip/override is an error", function()
	for _, key in ipairs({ "absent", "skip", "override" }) do
		local root = new_tree("baddefault")
		wf(root .. "/dots.lua", ("return { ['$default_attrs'] = { %s = true } }"):format(key))
		wf(root .. "/f", "f")
		local ok, err = pcall(plan.tree, root)
		t.truthy(not ok, "$default_attrs with " .. key .. " must fail")
		t.contains(tostring(err), "$default_attrs")
	end
end)

t.case("tree: $ignore files and dirs, ** across segments", function()
	local root = txtar.unpack([[-- dots.lua --
return { ["$ignore"] = { "*.bak", "secrets/", "**/.DS_Store" } }
-- keep.conf --
k
-- drop.bak --
d
-- secrets/password.txt --
p
-- sub/x.conf --
x
-- sub/.DS_Store --
junk
-- sub/deep/.DS_Store --
junk
]])
	local entries = plan.tree(root)
	t.eq(dests(entries), "~/keep.conf,~/sub/x.conf")
end)

t.case("tree: .git, .makac, dots.lua are auto-ignored everywhere", function()
	local root = txtar.unpack([[-- .git/config --
g
-- .makac/dots/host --
m
-- dots.lua --
return {}
-- sub/dots.lua --
return {}
-- sub/.git/x --
g
-- real.conf --
r
]])
	-- only real.conf; sub's dots.lua is reserved, sub/.git dropped
	t.eq(dests(plan.tree(root)), "~/real.conf")
end)

t.case("tree: nested dots.lua policies are independent", function()
	local root = txtar.unpack([[root dots.lua: mode 0644; sub dots.lua: mode 0600 + ignores tmp/
-- dots.lua --
return { ["$default_attrs"] = { mode = "0644" } }
-- sub/dots.lua --
return { ["$default_attrs"] = { mode = "0600" }, ["$ignore"] = { "tmp/" } }
-- top.conf --
t
-- sub/inner.conf --
i
-- sub/tmp/scratch --
s
-- sub/tmp/deep/more --
m
]])
	local m = by_dest(plan.tree(root))
	t.eq(m["~/top.conf"].mode, "0644")
	t.eq(m["~/sub/inner.conf"].mode, "0600", "nested $default_attrs governs its own dir")
	t.truthy(m["~/sub/tmp/scratch"] == nil, "nested $ignore not descended into")
	t.truthy(m["~/sub/tmp/deep/more"] == nil)
end)

t.case("tree: override precedence entry > $override > call-site > false", function()
	local root = txtar.unpack([[predicate selects *.local; explicit entries win over it
-- dots.lua --
return {
	["$override"] = function(file) return file.name:match("%.local$") ~= nil end,
	["foo.conf"] = { override = true },
	["bar.local"] = { override = false },
}
-- foo.conf --
f
-- bar.local --
b
-- baz.local --
z
-- plain.conf --
p
]])
	-- no call-site override
	local m = by_dest(plan.tree(root))
	t.eq(m["~/foo.conf"].override, true, "per-entry wins over the predicate")
	t.eq(m["~/bar.local"].override, false, "per-entry false wins over the predicate")
	t.eq(m["~/baz.local"].override, true, "$override function selected")
	t.eq(m["~/plain.conf"].override, false, "$override function rejected")
	-- call-site true: dots.lua still wins
	local m2 = by_dest(plan.tree(root, { override = true }))
	t.eq(m2["~/plain.conf"].override, false)
	t.eq(m2["~/foo.conf"].override, true)
	-- a dots.lua-less tree takes the call-site value
	local root2 = txtar.unpack("-- x.conf --\nx\n")
	t.eq(plan.tree(root2, { override = true })[1].override, true, "call-site default when no dots.lua")
	t.eq(plan.tree(root2)[1].override, false, "false when nothing says otherwise")
	-- boolean $override
	local root3 = txtar.unpack([[-- dots.lua --
return { ['$override'] = true }
-- y.conf --
y
]])
	t.eq(plan.tree(root3)[1].override, true, "plain boolean $override")
	-- the callback receives the whole file context, dest included (as written);
	-- the predicate lives in the file's own directory (dots.lua is dir-local)
	local root4 = txtar.unpack([[-- shallow.conf --
shallow
-- deep/dots.lua --
return { ['$override'] = function(file) return file.dest == '~/deep/f.conf' end }
-- deep/f.conf --
deep
]])
	local m4 = by_dest(plan.tree(root4))
	t.eq(m4["~/deep/f.conf"].override, true, "predicate consulted file.dest")
	t.eq(m4["~/shallow.conf"].override, false)
end)

t.case("tree: renderer captured from a dots.lua entry", function()
	local root = txtar.unpack([[-- dots.lua --
return { ["r.conf"] = { renderer = function(c) return c:upper() end } }
-- r.conf --
r
]])
	local e = plan.tree(root)[1]
	t.eq(type(e.renderer), "function")
	t.eq(e.renderer("abc"), "ABC")
end)

t.case("tree: function entries — shorthand renderer on a real file", function()
	local root = txtar.unpack([[-- dots.lua --
return { ["cfg"] = function(c) return c:upper() end }
-- cfg --
hello
]])
	local e = plan.tree(root)[1]
	t.eq(e.dest, "~/cfg")
	t.eq(e.content, "HELLO\n", "function received the file bytes (txtar trailing newline included)")
	t.eq(e.src, nil, "computed entries carry content, not src")
end)

t.case("tree: virtual entries — function with no file on disk", function()
	local root = txtar.unpack([[-- dots.lua --
return {
	["$default_attrs"] = { mode = "0600" },
	["computed.conf"] = function()
		return "generated\n"
	end,
	["full.conf"] = function()
		return { content = "full\n", mode = "0444" }
	end,
}
-- real.conf --
r
]])
	local m = by_dest(plan.tree(root))
	t.eq(m["~/computed.conf"].content, "generated\n")
	t.eq(m["~/computed.conf"].mode, "0600", "$default_attrs fills the gaps of function entries")
	t.eq(m["~/full.conf"].content, "full\n")
	t.eq(m["~/full.conf"].mode, "0444", "returned table attrs win")
	t.eq(m["~/real.conf"].src, "real.conf", "real files unaffected")
end)

t.case("tree: attr table naming a missing file is a loud error", function()
	local root = txtar.unpack([[-- dots.lua --
return { ["typo.conf"] = { mode = "0600" } }
-- real.conf --
r
]])
	local ok, err = pcall(plan.tree, root)
	t.truthy(not ok, "walk must fail")
	t.contains(tostring(err), "typo.conf")
	t.contains(tostring(err), "not in the tree")
end)

t.case("tree: $ctx — table and function forms, and table-form renderers get it too", function()
	local root = txtar.unpack([[-- dots.lua --
return {
	["$ctx"] = function() return { theme = "dark" } end,
	["a"] = function(c, ctx) return "a:" .. ctx.theme end,
	["b"] = function(c, ctx) return "b:" .. ctx.theme end,
}
]])
	local m = by_dest(plan.tree(root))
	t.eq(m["~/a"].content, "a:dark")
	t.eq(m["~/b"].content, "b:dark")
	local root2 = txtar.unpack([[-- dots.lua --
return {
	["$ctx"] = { who = "ctx" },
	["f"] = { renderer = function(c, ctx) return c .. "/" .. ctx.who end },
}
-- f --
plain
]])
	t.eq(plan.tree(root2)[1].renderer("plain"), "plain/ctx", "ctx threaded into table-form renderers")
end)

t.case("tree: source symlinks", function()
	-- txtar cannot express symlinks, so links are created after the unpack
	local root = txtar.unpack("-- real.txt --\ncontent\n")
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

t.case("tree: load_sidecar, and dots.lua using PROJECT_DIR", function()
	local root = txtar.unpack([[-- shared.lua --
return { mode = '0600' }
-- f.conf --
f
]])
	t.eq(plan.load_dotsfile(root), nil, "nil when absent")
	wf(root .. "/dots.lua", [[
local d = dofile(PROJECT_DIR .. "/shared-in-project.lua")
return { ["$default_attrs"] = d }]])
	-- PROJECT_DIR is the makac.dots project root when tests run under it
	makac.fs.write_file(tostring(PROJECT_DIR) .. "/shared-in-project.lua", "return { mode = '0600' }")
	local m = by_dest(plan.tree(root))
	t.eq(m["~/f.conf"].mode, "0600", "dots.lua composed via dofile(PROJECT_DIR .. ...)")
	makac.exec({ "rm", "-f", tostring(PROJECT_DIR) .. "/shared-in-project.lua" })
	-- a broken dots.lua is a loud error, not a skip
	wf(root .. "/dots.lua", "this is not lua")
	local ok, err = pcall(plan.load_dotsfile, root)
	t.truthy(not ok)
	t.contains(tostring(err), "dots.lua")
end)

-- ---------------------------------------------------------------- dots:apply

local function read_in(tgt, rel)
	return makac.fs.read_file(tgt.root .. "/" .. rel)
end

t.case("apply: 3-file tree, first run changed, second all ok", function()
	local root = txtar.unpack([==[-- a.conf --
aaa
-- sub/b.conf --
bbb
-- sub/deep/c.conf --
ccc
]==])
	local tgt = new_target("apply3")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true, "first run changed")
	t.eq(#r.out.changed, 3)
	t.eq(#r.out.failed, 0)
	t.eq(read_in(tgt, "a.conf"), "aaa\n")
	t.eq(read_in(tgt, "sub/b.conf"), "bbb\n")
	t.eq(read_in(tgt, "sub/deep/c.conf"), "ccc\n")
	-- idempotent: second run is all ok
	local r2 = action_apply.apply({ root = root, target = tgt })
	t.eq(r2.err, nil)
	t.eq(r2.changed, false, "second run unchanged")
	t.eq(#r2.out.ok, 3)
	t.eq(#r2.out.changed, 0)
end)

t.case("apply: one conflict does not stop the loop, err stays unset", function()
	local root = txtar.unpack([==[-- first.conf --
one
-- conflicted.conf --
desired
-- last.conf --
three
]==])
	local tgt = new_target("applyconflict")
	txtar.unpack([==[-- conflicted.conf --
local edit
]==], tgt.root)
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil, "per-file failure is data, never err")
	t.eq(r.changed, true, "the other files changed")
	t.eq(#r.out.failed, 1)
	t.eq(r.out.failed[1].path, "~/conflicted.conf")
	t.contains(r.out.failed[1].err, "conflict")
	t.eq(read_in(tgt, "conflicted.conf"), "local edit\n", "loser left untouched")
	t.eq(read_in(tgt, "first.conf"), "one\n")
	-- the loop CONTINUED past the failure into the entry after it:
	t.eq(read_in(tgt, "last.conf"), "three\n", "entries after the failure still applied")
end)

t.case("apply: strict=true turns failures into err", function()
	local root = txtar.unpack([==[-- a.conf --
a
-- b.conf --
b
]==])
	local tgt = new_target("applystrict")
	txtar.unpack([==[-- a.conf --
differing
]==], tgt.root)
	local r = action_apply.apply({ root = root, target = tgt, strict = true })
	t.truthy(r.err ~= nil, "strict aborts")
	t.contains(r.err, "strict")
	t.eq(read_in(tgt, "b.conf"), "b\n", "non-failing entries still applied before err")
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
	txtar.unpack([==[-- gone.conf --
stale
]==], tgt.root)
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
	local root = txtar.unpack([==[-- a.conf --
aaa
-- b.conf --
bbb
]==])
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
	-- check mode reports a target-only user edit WITHOUT counting it failed
	-- (the user editing their own target config never broke anything)
	makac.fs.write_file(tgt.root .. "/a.conf", "local edit")
	local r3 = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r3.err, nil)
	t.eq(#r3.out.failed, 0)
	t.eq(#r3.out.target_only, 1)
	t.eq(read_in(tgt, "a.conf"), "local edit", "check wrote nothing")
	-- a genuine divergence (BOTH moved) still counts as a conflict failure
	makac.fs.write_file(root .. "/a.conf", "new source")
	local r4 = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(#r4.out.failed, 1)
end)

t.case("apply: link entries route to dots:link", function()
	local root = txtar.unpack([==[-- dots.lua --
return { ["linked"] = { link = "../elsewhere/target" } }
-- linked --
ignored bytes
-- plain.conf --
p
]==])
	local tgt = new_target("applylink")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(makac.fs.stat(tgt.root .. "/linked").type, "link", "a symlink was made")
	t.eq(read_in(tgt, "plain.conf"), "p\n")
end)

t.case("apply: requires root or files, and refuses both", function()
	local r = action_apply.apply({})
	t.truthy(r.err ~= nil)
	t.contains(r.err, "root")
	local r2 = action_apply.apply({ root = "t", files = {} })
	t.truthy(r2.err ~= nil, "both given is an error, not a silent pick")
	t.contains(r2.err, "not both")
end)

-- ---------------------------------------------------------------- dots:diff

local action_diff = require("pkgs/dots/action_diff")

t.case("diff: converged tree reports nothing", function()
	local root = txtar.unpack("-- a.conf --\naaa\n")
	local tgt = new_target("diffconv")
	action_apply.apply({ root = root, target = tgt })
	local r = action_diff.diff({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, false, "no drift -> not changed")
	t.eq(#r.out.differing, 0)
	t.eq(#r.out.mode_drift, 0)
	t.eq(r.out.drifted, false)
	t.eq(#r.out.ok, 1)
end)

t.case("diff: content drift, new files, and mode drift", function()
	local root = txtar.unpack([[-- dots.lua --
return { ["m.conf"] = { skip = true } }
-- old.conf --
desired content
-- new.conf --
fresh
-- m.conf --
mode-only
]])
	local tgt = new_target("diffdrift")
	-- skip entry must not even be inspected
	txtar.unpack("-- old.conf --\ndrifted content\n-- m.conf --\nmode-only\n", tgt.root)
	makac.exec({ "chmod", "0600", "--", tgt.root .. "/m.conf" })
	local r = action_diff.diff({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, false, "reporting changes nothing")
	t.eq(r.out.drifted, true, "the drift signal is out.drifted")
	t.eq(#r.out.differing, 2)
	t.eq(#r.out.mode_drift, 0)
	t.eq(#r.out.skipped, 1)
	local items = {}
	for _, it in ipairs(r.out.entries) do items[it.dest] = it end
	t.contains(items["~/old.conf"].content, "-drifted content")
	t.contains(items["~/old.conf"].content, "+desired content")
	t.contains(items["~/old.conf"].content, "--- a/~/old.conf", "patch-readable labels")
	t.contains(items["~/new.conf"].content, "+fresh", "new files: content shown as additions")
end)

t.case("diff: mode drift on byte-identical file; symlink and absent notes", function()
	local root = txtar.unpack([[-- dots.lua --
return {
	["keep.conf"] = { mode = "0600" },
	["gone.conf"] = { absent = true },
	["lnk"] = { link = "../real" },
}
-- keep.conf --
same bytes
]])
	local tgt = new_target("diffmode")
	txtar.unpack("-- keep.conf --\nsame bytes\n-- gone.conf --\nstale\n", tgt.root)
	makac.exec({ "chmod", "0644", "--", tgt.root .. "/keep.conf" }) -- drift the mode
	makac.fs.symlink("../elsewhere", tgt.root .. "/lnk")
	local r = action_diff.diff({ root = root, target = tgt })
	t.eq(r.err, nil)
	local items = {}
	for _, it in ipairs(r.out.entries) do items[it.dest] = it end
	t.eq(items["~/keep.conf"].content, nil, "bytes identical: no content drift")
	t.eq(items["~/keep.conf"].mode.have, "644")
	t.eq(items["~/keep.conf"].mode.want, "0600")
	t.contains(items["~/lnk"].content, "symlink target")
	t.contains(items["~/gone.conf"].content, "--- a/~/gone.conf", "absent entry: file -> /dev/null")
	t.eq(r.changed, false)
	t.eq(r.out.drifted, true)
end)

t.case("diff: refuses root+files, renders the two-section report", function()
	local r = action_diff.diff({ root = "t", files = {} })
	t.truthy(r.err ~= nil)
	t.contains(r.err, "not both")
	local libdiff = require("pkgs/dots/diff")
	local text = libdiff.render({
		{ dest = "~/a", content = "unified diff here" },
		{ dest = "~/b", mode = { have = "644", want = "0600" } },
		{ dest = "~/ok" },
	})
	t.contains(text, "## contents\nunified diff here")
	t.contains(text, "## modes\nMODE ~/b: 644 -> 0600")
	t.truthy(text:find("## contents") < text:find("## modes"), "contents section first")
	t.eq(libdiff.render({ { dest = "~/ok" } }), "", "converged renders empty")
end)

-- ---------------------------------------------------------------- snapshot

local snapshot = require("pkgs/dots/snapshot")

-- test-only helper: plant raw entry bytes into the fake target's store
-- (the fake target's root IS a host dir; blackbox covers real targets).
local function plant(tgt, root, relpath, raw)
	local p = tgt.root .. "/.makac/dots/snapshot/" .. snapshot.hash(relpath)
	makac.fs.mkdir_p((p:gsub("/[^/]*$", "")))
	makac.fs.write_file(p, raw)
	return p
end

t.case("snapshot: hash is a stable lowercase hex sha256 of the relpath", function()
	local h1 = snapshot.hash(".config/foo/config")
	t.eq(h1, snapshot.hash(".config/foo/config"), "stable")
	t.truthy(h1:match("^%x+$") and #h1 == 64, "64 lowercase hex chars")
	t.truthy(h1 ~= snapshot.hash(".config/foo/other"), "relpath-keyed")
	t.eq(h1, makac.sha256(".config/foo/config"), "verbatim hash, no normalization")
end)

t.case("snapshot: write -> read round-trip incl. mode/owner", function()
	local tgt = new_target("snap-rt")
	local root = tgt.root
	local ok, err = snapshot.write(tgt, root, ".config/app.conf",
		{ tree = "mydots", kind = "file", mode = "0600", owner = "nixos:users" },
		"key = value\n")
	t.truthy(ok, "write ok: " .. tostring(err))
	local e, rerr = snapshot.read(tgt, root, ".config/app.conf")
	t.truthy(e, "read ok: " .. tostring(rerr))
	t.eq(e.meta.file, ".config/app.conf")
	t.eq(e.meta.tree, "mydots")
	t.eq(e.meta.kind, "file")
	t.eq(e.meta.mode, "0600")
	t.eq(e.meta.owner, "nixos:users")
	t.eq(e.meta.sha256, makac.sha256("key = value\n"))
	t.eq(e.body, "key = value\n", "body verbatim")
	-- store perms: dir 0700, entry 0600, whole .makac chain locked down
	local snapdir = tgt.root .. "/.makac/dots/snapshot"
	t.eq(mode_of(snapdir), "700")
	t.eq(mode_of(tgt.root .. "/.makac/dots"), "700")
	t.eq(mode_of(tgt.root .. "/.makac"), "700")
	t.eq(mode_of(snapdir .. "/" .. snapshot.hash(".config/app.conf")), "600")
	-- rewrite replaces wholesale
	t.truthy(snapshot.write(tgt, root, ".config/app.conf",
		{ tree = "mydots", kind = "file" }, "v2"))
	local e2 = snapshot.read(tgt, root, ".config/app.conf")
	t.eq(e2.body, "v2")
	t.eq(e2.meta.mode, nil, "omitted mode stays omitted")
	t.eq(e2.meta.owner, nil)
end)

t.case("snapshot: binary body round-trips verbatim", function()
	local tgt = new_target("snap-bin")
	local bin = "A\0B\255\1\nno-trailing-newline\0"
	t.truthy(snapshot.write(tgt, tgt.root, "bin/blob",
		{ tree = "t", kind = "file" }, bin))
	local e, err = snapshot.read(tgt, tgt.root, "bin/blob")
	t.truthy(e, tostring(err))
	t.eq(e.body, bin, "NULs and high bytes survive")
	t.eq(#e.body, #bin)
end)

t.case("snapshot: link and dir entries", function()
	local tgt = new_target("snap-kinds")
	-- link: body is the stored target string
	t.truthy(snapshot.write(tgt, tgt.root, ".config/link",
		{ tree = "t", kind = "link" }, "../elsewhere/x"))
	local l = snapshot.read(tgt, tgt.root, ".config/link")
	t.eq(l.meta.kind, "link")
	t.eq(l.body, "../elsewhere/x")
	t.eq(l.meta.sha256, makac.sha256("../elsewhere/x"))
	-- dir: no body, sha256 of empty
	t.truthy(snapshot.write(tgt, tgt.root, ".config",
		{ tree = "t", kind = "dir", mode = "0700" }, ""))
	local d = snapshot.read(tgt, tgt.root, ".config")
	t.eq(d.meta.kind, "dir")
	t.eq(d.body, "")
	t.eq(d.meta.sha256, makac.sha256(""))
end)

t.case("snapshot: absent entry reads nil WITHOUT error", function()
	local tgt = new_target("snap-absent")
	local e, err = snapshot.read(tgt, tgt.root, "never/written")
	t.eq(e, nil, "absent")
	t.eq(err, nil, "no error for mere absence (2-way fallback is normal)")
end)

t.case("snapshot: list parses headers only, sorted, empty when no store", function()
	local tgt = new_target("snap-list")
	t.eq(#snapshot.list(tgt, tgt.root), 0, "no snapshot dir -> empty list")
	snapshot.write(tgt, tgt.root, "b/x.conf", { tree = "mine", kind = "file" }, "bx")
	snapshot.write(tgt, tgt.root, "a/y.conf",
		{ tree = "mine", kind = "file", mode = "0644" }, "ay")
	snapshot.write(tgt, tgt.root, "c", { tree = "other", kind = "dir" }, "")
	local l, err = snapshot.list(tgt, tgt.root)
	t.truthy(l, tostring(err))
	t.eq(#l, 3)
	t.eq(l[1].relpath, "a/y.conf", "sorted by relpath")
	t.eq(l[2].relpath, "b/x.conf")
	t.eq(l[3].relpath, "c")
	t.eq(l[1].meta.tree, "mine", "meta parsed from header")
	t.eq(l[1].meta.mode, "0644")
	t.eq(l[3].meta.tree, "other", "foreign owner visible to prune")
	t.eq(l[1].body, nil, "list carries no bodies")
end)

t.case("snapshot: strict magic rejection", function()
	local tgt = new_target("snap-magic")
	local root = tgt.root
	-- garbage line 1
	plant(tgt, root, "bad1", "nope\n{}\nbody")
	local e, err = snapshot.read(tgt, root, "bad1")
	t.eq(e, nil)
	t.contains(tostring(err), "malformed magic")
	-- newer version rejected loudly
	plant(tgt, root, "bad2", "--- makac.dots,2\n{}\nbody")
	local e2, err2 = snapshot.read(tgt, root, "bad2")
	t.eq(e2, nil)
	t.contains(tostring(err2), "newer than supported")
	-- near-miss: space before the comma
	plant(tgt, root, "bad3", "--- makac.dots ,1\n{}\nbody")
	local e3, err3 = snapshot.read(tgt, root, "bad3")
	t.eq(e3, nil)
	t.contains(tostring(err3), "malformed magic")
	-- wrong product name
	plant(tgt, root, "bad4", "--- something.else,1\n{}\nbody")
	local _, err4 = snapshot.read(tgt, root, "bad4")
	t.contains(tostring(err4), "not a makac.dots snapshot entry")
	-- truncated: no metadata line
	plant(tgt, root, "bad5", "--- makac.dots,1")
	local _, err5 = snapshot.read(tgt, root, "bad5")
	t.contains(tostring(err5), "truncated")
	-- malformed metadata JSON
	plant(tgt, root, "bad6", "--- makac.dots,1\n{ nope\nbody")
	local _, err6 = snapshot.read(tgt, root, "bad6")
	t.contains(tostring(err6), "metadata")
	-- a good entry amongst corrupt ones: read is fine, LIST fails loudly
	t.truthy(snapshot.write(tgt, root, "good", { tree = "t", kind = "file" }, "ok"))
	local g = snapshot.read(tgt, root, "good")
	t.eq(g.body, "ok")
	local l, lerr = snapshot.list(tgt, root)
	t.eq(l, nil, "corrupt entry fails the whole list")
	t.truthy(lerr ~= nil)
end)

t.case("snapshot: remove drops entries", function()
	local tgt = new_target("snap-rm")
	snapshot.write(tgt, tgt.root, "a", { tree = "t", kind = "file" }, "1")
	snapshot.write(tgt, tgt.root, "b", { tree = "t", kind = "file" }, "2")
	t.eq(#snapshot.list(tgt, tgt.root), 2)
	t.truthy(snapshot.remove(tgt, tgt.root, { "a" }))
	local l = snapshot.list(tgt, tgt.root)
	t.eq(#l, 1)
	t.eq(l[1].relpath, "b")
	t.eq(snapshot.read(tgt, tgt.root, "a"), nil, "dropped entry reads absent")
	-- removing an absent entry is fine (idempotent)
	t.truthy(snapshot.remove(tgt, tgt.root, { "gone" }))
end)

t.case("snapshot: dest roots are independent namespaces", function()
	local tgt = new_target("snap-ns")
	local ra = tgt.root .. "/ra"
	local rb = tgt.root .. "/rb"
	snapshot.write(tgt, ra, "x.conf", { tree = "t", kind = "file" }, "x")
	t.eq(#snapshot.list(tgt, ra), 1)
	t.eq(#snapshot.list(tgt, rb), 0, "separate DEST, separate store")
	t.eq(snapshot.read(tgt, rb, "x.conf"), nil)
end)

-- ------------------------------------------------- apply: snapshot recording

t.case("apply+snapshot: apply records entries for a walked tree", function()
	local root = txtar.unpack([==[-- dots.lua --
return { ["$tree"] = "dotproj", ["modey.conf"] = { mode = "0600" }, ["lnk"] = { link = "a.conf" } }
-- a.conf --
aaa
-- sub/b.conf --
bbb
-- modey.conf --
m
]==])
	local tgt = new_target("snap-apply")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(#r.out.failed, 0)
	local l, lerr = snapshot.list(tgt, "~")
	t.truthy(l, tostring(lerr))
	t.eq(#l, 4)
	t.eq(l[1].relpath, "a.conf")
	t.eq(l[1].meta.tree, "dotproj", "owner id from root dots.lua $tree")
	t.eq(l[4].relpath, "sub/b.conf")
	local e = snapshot.read(tgt, "~", "sub/b.conf")
	t.eq(e.body, "bbb\n", "deployed bytes recorded verbatim")
	t.eq(e.meta.sha256, makac.sha256("bbb\n"))
	t.eq(e.meta.kind, "file")
	t.eq(e.meta.mode, nil, "mode omitted when the entry does not carry it")
	local m = snapshot.read(tgt, "~", "modey.conf")
	t.eq(m.meta.mode, "0600", "entry attrs recorded")
	local lk = snapshot.read(tgt, "~", "lnk")
	t.eq(lk.meta.kind, "link")
	t.eq(lk.body, "a.conf", "link entries record the stored target string")
end)

t.case("apply+snapshot: owner id precedence with.tree > $tree > basename(root)", function()
	-- with.tree beats $tree
	local root = txtar.unpack([==[-- dots.lua --
return { ["$tree"] = "intree" }
-- a.conf --
a
]==])
	local tgt = new_target("snap-prec-a")
	action_apply.apply({ root = root, target = tgt, tree = "cli" })
	local e = snapshot.read(tgt, "~", "a.conf")
	t.eq(e.meta.tree, "cli", "with.tree beats $tree")
	-- neither set: basename of the root
	local root2 = txtar.unpack("-- b.conf --\nb\n")
	local tgt2 = new_target("snap-prec-b")
	action_apply.apply({ root = root2, target = tgt2 })
	local e2 = snapshot.read(tgt2, "~", "b.conf")
	t.eq(e2.meta.tree, (root2:gsub("/+$", "")):match("[^/]+$"), "basename(root) fallback")
	-- $tree alone (covered by the recording case): and a bad $tree is a loud walk error
	local root3 = txtar.unpack([==[-- dots.lua --
return { ["$tree"] = 42 }
-- c.conf --
c
]==])
	local r3 = action_apply.apply({ root = root3, target = tgt2 })
	t.truthy(r3.err ~= nil, "non-string $tree fails the walk")
end)

t.case("apply+snapshot: absent removal drops the entry (no graveyard)", function()
	local root = txtar.unpack("-- a.conf --\naaa\n")
	local tgt = new_target("snap-absdrop")
	action_apply.apply({ root = root, target = tgt })
	t.truthy(snapshot.read(tgt, "~", "a.conf") ~= nil, "tracked before removal")
	local root2 = txtar.unpack([==[-- dots.lua --
return { ["a.conf"] = { absent = true } }
]==])
	local r = action_apply.apply({ root = root2, target = tgt })
	t.eq(r.err, nil)
	t.eq(read_in(tgt, "a.conf"), nil, "removed target")
	t.eq(snapshot.read(tgt, "~", "a.conf"), nil, "snapshot entry dropped")
end)

t.case("apply+snapshot: converged pre-snapshot deployments backfill", function()
	local root = txtar.unpack("-- a.conf --\naaa\n")
	local tgt = new_target("snap-backfill")
	-- deployed before snapshots existed: target converged, nothing recorded
	makac.fs.write_file(tgt.root .. "/a.conf", "aaa\n")
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, false, "converged: nothing written")
	t.eq(#r.out.ok, 1)
	local e = snapshot.read(tgt, "~", "a.conf")
	t.truthy(e ~= nil, "backfilled")
	t.eq(e.body, "aaa\n", "backfill records the target (= desired) bytes")
end)

t.case("apply+snapshot: chmod-only refresh keeps the body, updates mode", function()
	local root = txtar.unpack([==[-- dots.lua --
return { ["m.conf"] = { mode = "0600" } }
-- m.conf --
body-v1
]==])
	local tgt = new_target("snap-chmod")
	action_apply.apply({ root = root, target = tgt })
	-- drift the mode out from under it
	makac.exec({ "chmod", "0644", tgt.root .. "/m.conf" })
	local r = action_apply.apply({ root = root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true, "mode drift fixed")
	t.eq(mode_of(tgt.root .. "/m.conf"), "600")
	local e = snapshot.read(tgt, "~", "m.conf")
	t.eq(e.body, "body-v1\n", "same body kept")
	t.eq(e.meta.mode, "0600", "meta refreshed")
end)

t.case("apply+snapshot: check mode records nothing", function()
	local root = txtar.unpack("-- a.conf --\naaa\n")
	local tgt = new_target("snap-check")
	local r = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r.changed, true, "would change")
	t.eq(makac.fs.stat(tgt.root .. "/.makac"), nil, "no store created")
	t.eq(#snapshot.list(tgt, "~"), 0, "nothing recorded")
end)

t.case("apply+snapshot: files= tracks only with tree and under the prefix", function()
	local tgt = new_target("snap-files")
	-- without tree: deployed but untracked
	local r1 = action_apply.apply({ target = tgt, files = {
		{ dest = "~/a.conf", content = "a\n" },
	} })
	t.eq(r1.err, nil)
	t.eq(snapshot.read(tgt, "~", "a.conf"), nil, "no tree -> untracked")
	-- with tree: under-prefix dests are tracked, outside-prefix ones are not
	local outside = tostring(makac.fs.mktemp_dir("dots-outside-")) .. "/b.conf"
	local r2 = action_apply.apply({ target = tgt, tree = "t", files = {
		{ dest = "~/b.conf", content = "b\n" },
		{ dest = outside, content = "outside\n" },
	} })
	t.eq(r2.err, nil)
	t.truthy(snapshot.read(tgt, "~", "b.conf") ~= nil, "under prefix -> tracked")
	local l = snapshot.list(tgt, "~")
	t.eq(#l, 1, "outside-prefix entry not recorded")
	t.eq(l[1].relpath, "b.conf")
end)

-- --------------------------------------------------------------- classify

local classify = require("pkgs/dots/classify")

-- count target:get calls (fetch/snapshot reads) per source path
local function watch_gets(tgt)
	local gets = {}
	local orig_get = tgt.get
	tgt.get = function(self, src, dst)
		gets[#gets + 1] = src
		return orig_get(self, src, dst)
	end
	return gets
end

t.case("classify: converged tracked entry; cheap path (one target touch)", function()
	local tgt = new_target("cls-conv")
	makac.fs.write_file(tgt.root .. "/a.conf", "aaa\n")
	snapshot.write(tgt, "~", "a.conf", { tree = "t", kind = "file" }, "aaa\n")
	local gets = watch_gets(tgt)
	local r, err = classify.one(tgt, "~", { relpath = "a.conf", dest = "~/a.conf", content = "aaa\n" })
	t.truthy(r, tostring(err))
	t.eq(r.state, "converged")
	t.eq(r.deployed, "aaa\n", "deployed bytes ride along for merging")
	t.eq(r.source, "aaa\n")
	t.truthy(r.target_sha ~= nil)
	t.eq(r.kind_mismatch, nil)
	-- exactly one fetch of the target path (the sha op) + one store read
	local live_fetches = 0
	for _, p in ipairs(gets) do
		if p:match("/a%.conf$") then live_fetches = live_fetches + 1 end
	end
	t.eq(live_fetches, 1, "target bytes are never fetched — only the sha op")
	t.eq(#gets, 2, "target sha + one store read, nothing else")
end)

t.case("classify: ff — target untouched, source moved", function()
	local tgt = new_target("cls-ff")
	makac.fs.write_file(tgt.root .. "/f.conf", "old\n")
	snapshot.write(tgt, "~", "f.conf", { tree = "t", kind = "file" }, "old\n")
	local r = classify.one(tgt, "~", { relpath = "f.conf", dest = "~/f.conf", content = "new\n" })
	t.eq(r.state, "ff")
	t.eq(r.deployed, "old\n")
	t.eq(r.source, "new\n")
end)

t.case("classify: target-only — user edit only, source matches deployed", function()
	local tgt = new_target("cls-liveonly")
	makac.fs.write_file(tgt.root .. "/f.conf", "edited\n")
	snapshot.write(tgt, "~", "f.conf", { tree = "t", kind = "file" }, "old\n")
	local r = classify.one(tgt, "~", { relpath = "f.conf", dest = "~/f.conf", content = "old\n" })
	t.eq(r.state, "target-only")
	t.eq(r.deployed, "old\n")
	t.eq(r.source, "old\n")
	t.truthy(r.target_sha ~= nil and r.target_sha ~= r.meta.sha256)
end)

t.case("classify: diverged — both moved apart", function()
	local tgt = new_target("cls-div")
	makac.fs.write_file(tgt.root .. "/f.conf", "target\n")
	snapshot.write(tgt, "~", "f.conf", { tree = "t", kind = "file" }, "deployed\n")
	local r = classify.one(tgt, "~", { relpath = "f.conf", dest = "~/f.conf", content = "source\n" })
	t.eq(r.state, "diverged")
	t.eq(r.deployed, "deployed\n")
	t.eq(r.source, "source\n")
end)

t.case("classify: new — no target node; and tracked-file-delete is new too", function()
	local tgt = new_target("cls-new")
	local r = classify.one(tgt, "~", { relpath = "f.conf", dest = "~/f.conf", content = "x\n" })
	t.eq(r.state, "new")
	t.eq(r.meta, nil, "untracked")
	t.eq(r.target_sha, nil)
	t.eq(r.source, nil, "source bytes not computed for a bare deploy")
	-- tracked file deleted target: still 'new', but meta tells the caller the
	-- user deleted a tracked file
	snapshot.write(tgt, "~", "gone.conf", { tree = "t", kind = "file" }, "g\n")
	local r2 = classify.one(tgt, "~", { relpath = "gone.conf", dest = "~/gone.conf", content = "g\n" })
	t.eq(r2.state, "new")
	t.truthy(r2.meta ~= nil, "deployed record says it was tracked")
	t.eq(r2.deployed, "g\n")
end)

t.case("classify: absent-pending, converged absent, dir refusal", function()
	local tgt = new_target("cls-absent")
	makac.fs.write_file(tgt.root .. "/old.conf", "old\n")
	local r = classify.one(tgt, "~", { relpath = "old.conf", dest = "~/old.conf", absent = true })
	t.eq(r.state, "absent-pending")
	t.eq(r.target_sha, makac.sha256("old\n"), "target hash reported for files")
	-- stale store entry, target already gone: still pending (drop the entry)
	snapshot.write(tgt, "~", "stale.conf", { tree = "t", kind = "file" }, "s\n")
	local r2 = classify.one(tgt, "~", { relpath = "stale.conf", dest = "~/stale.conf", absent = true })
	t.eq(r2.state, "absent-pending")
	-- nothing target, nothing recorded: converged
	local r3 = classify.one(tgt, "~", { relpath = "never.conf", dest = "~/never.conf", absent = true })
	t.eq(r3.state, "converged")
	-- target dir: surface the mismatch (absent never removes directories)
	makac.fs.mkdir_p(tgt.root .. "/dirconf")
	local r4 = classify.one(tgt, "~", { relpath = "dirconf", dest = "~/dirconf", absent = true })
	t.eq(r4.state, "absent-pending")
	t.eq(r4.kind_mismatch, "dir")
end)

t.case("classify: untracked 2-way fallback", function()
	local tgt = new_target("cls-untracked")
	makac.fs.write_file(tgt.root .. "/same.conf", "same\n")
	makac.fs.write_file(tgt.root .. "/diff.conf", "local\n")
	local r1 = classify.one(tgt, "~", { relpath = "same.conf", dest = "~/same.conf", content = "same\n" })
	t.eq(r1.state, "untracked-same")
	t.eq(r1.meta, nil)
	local r2 = classify.one(tgt, "~", { relpath = "diff.conf", dest = "~/diff.conf", content = "desired\n" })
	t.eq(r2.state, "untracked-conflict")
	t.eq(r2.source, "desired\n")
end)

t.case("classify: mode/owner drift flags without changing content state", function()
	local tgt = new_target("cls-drift")
	makac.fs.write_file(tgt.root .. "/m.conf", "m\n")
	makac.exec({ "chmod", "0644", tgt.root .. "/m.conf" })
	snapshot.write(tgt, "~", "m.conf", { tree = "t", kind = "file", mode = "0600" }, "m\n")
	local r = classify.one(tgt, "~", {
		relpath = "m.conf", dest = "~/m.conf", content = "m\n",
		mode = "0600", owner = "root:root", -- nobody runs as root here -> drift
	})
	t.eq(r.state, "converged", "drift is orthogonal to content state")
	t.eq(r.mode_drift, true)
	t.eq(r.owner_drift, true)
	-- attrs matching: no drift
	makac.exec({ "chmod", "0600", tgt.root .. "/m.conf" })
	local r2 = classify.one(tgt, "~", { relpath = "m.conf", dest = "~/m.conf", content = "m\n", mode = "0600" })
	t.eq(r2.state, "converged")
	t.eq(r2.mode_drift, false)
	t.eq(r2.owner_drift, false)
end)

t.case("classify: kind mismatch — file entry over target dir or target link", function()
	local tgt = new_target("cls-kind")
	makac.fs.mkdir_p(tgt.root .. "/d.conf")
	local r = classify.one(tgt, "~", { relpath = "d.conf", dest = "~/d.conf", content = "x\n" })
	t.eq(r.state, "untracked-conflict", "exists-and-differs semantics")
	t.eq(r.kind_mismatch, "dir")
	makac.fs.symlink(tgt.root .. "/some-target", tgt.root .. "/l.conf")
	local r2 = classify.one(tgt, "~", { relpath = "l.conf", dest = "~/l.conf", content = "x\n" })
	t.eq(r2.kind_mismatch, "link")
	-- tracked: closest content state is diverged
	snapshot.write(tgt, "~", "d.conf", { tree = "t", kind = "file" }, "y\n")
	local r3 = classify.one(tgt, "~", { relpath = "d.conf", dest = "~/d.conf", content = "x\n" })
	t.eq(r3.state, "diverged")
	t.eq(r3.kind_mismatch, "dir")
end)

t.case("classify: link entries — converged, target-only, new, mismatch", function()
	local tgt = new_target("cls-link")
	-- converged: store + target both point at t1, entry wants t1
	makac.fs.symlink("t1", tgt.root .. "/lk1")
	snapshot.write(tgt, "~", "lk1", { tree = "t", kind = "link" }, "t1")
	local r = classify.one(tgt, "~", { relpath = "lk1", dest = "~/lk1", link = "t1" })
	t.eq(r.state, "converged")
	makac.fs.symlink("t2", tgt.root .. "/lk2")
	snapshot.write(tgt, "~", "lk2", { tree = "t", kind = "link" }, "t1") -- deployed t1
	local r2 = classify.one(tgt, "~", { relpath = "lk2", dest = "~/lk2", link = "t1" })
	t.eq(r2.state, "target-only", "user repointed the target link only")
	-- new
	local r3 = classify.one(tgt, "~", { relpath = "lk3", dest = "~/lk3", link = "t9" })
	t.eq(r3.state, "new")
	t.eq(r3.source, "t9", "link source is the stored target string")
	-- target real file under a link entry: dots:link refuses -> conflict
	makac.fs.write_file(tgt.root .. "/lk4", "real\n")
	local r4 = classify.one(tgt, "~", { relpath = "lk4", dest = "~/lk4", link = "t1" })
	t.eq(r4.state, "untracked-conflict")
	t.eq(r4.kind_mismatch, "file")
end)

t.case("classify: src entries via opts.root; entry.root wins", function()
	local root = txtar.unpack("-- s.conf --\nfrom-src\n")
	local tgt = new_target("cls-src")
	makac.fs.write_file(tgt.root .. "/s.conf", "from-src\n")
	local r = classify.one(tgt, "~", { relpath = "s.conf", dest = "~/s.conf", src = "s.conf" }, { root = root })
	t.eq(r.state, "untracked-same")
	t.eq(r.source, "from-src\n")
	-- without a root, src-relative entries fail loudly (caller bug, not a state)
	local r2, e2 = classify.one(tgt, "~", { relpath = "s.conf", dest = "~/s.conf", src = "s.conf" })
	t.eq(r2, nil)
	t.truthy(e2 ~= nil)
end)

t.case("classify: corrupt snapshot entry is an error, not a state", function()
	local tgt = new_target("cls-corrupt")
	makac.fs.write_file(tgt.root .. "/a.conf", "aaa\n")
	plant(tgt, tgt.root, "a.conf", "utter junk\n")
	local r, err = classify.one(tgt, "~", { relpath = "a.conf", dest = "~/a.conf", content = "aaa\n" })
	t.eq(r, nil)
	t.contains(tostring(err), "snapshot")
end)

t.case("classify: all preserves order and reports failures in place", function()
	local tgt = new_target("cls-all")
	makac.fs.write_file(tgt.root .. "/a.conf", "a\n")
	local out = classify.all(tgt, "~", {
		{ relpath = "a.conf", dest = "~/a.conf", content = "a\n" },
		{ dest = "/elsewhere/x.conf", content = "x\n" }, -- not under ~/, no relpath
		{ relpath = "b.conf", dest = "~/b.conf", content = "b\n" },
	})
	t.eq(#out, 3, "same order, same length")
	t.eq(out[1].state, "untracked-same")
	t.truthy(out[2].err ~= nil, "bad entry reported in place")
	t.eq(out[3].state, "new")
end)

-- --------------------------------- apply classification: ff / target-only /
-- --------------------------------- diverged; override == "may I overwrite
-- --------------------------------- user edits"

local function run_apply_tree(root, tgt, extra)
	local w = { root = root, target = tgt }
	for k, v in pairs(extra or {}) do w[k] = v end
	local ok, r = pcall(step, { uses = "dots:apply", name = "apply", with = w })
	t.truthy(ok, tostring(r))
	return r
end

t.case("apply: fast-forward — tree moved, target untouched, override=false", function()
	local root = txtar.unpack("-- c.conf --\nv1\n")
	local tgt = new_target("apply-ff")
	local r = run_apply_tree(root, tgt)
	t.eq(r.err, nil)
	t.eq(read_in(tgt, "c.conf"), "v1\n")
	-- the tree moves to v2; the target file was never edited: fast-forward
	makac.fs.write_file(root .. "/c.conf", "v2\n")
	local r2 = run_apply_tree(root, tgt) -- override=false (the default)
	t.eq(r2.err, nil)
	t.eq(#r2.out.failed, 0, "no conflict — there were no user edits")
	t.eq(#r2.out.target_only, 0)
	t.eq(#r2.out.changed, 1, "fast-forwarded")
	t.eq(read_in(tgt, "c.conf"), "v2\n")
	t.eq(snapshot.read(tgt, "~", "c.conf").body, "v2\n", "snapshot follows the fast-forward")
end)

t.case("apply: target-only user edit is reported, never clobbered", function()
	local root = txtar.unpack("-- c.conf --\nfrom-tree\n")
	local tgt = new_target("apply-lo")
	run_apply_tree(root, tgt)
	-- the user edits the LIVE file only; the source does not move
	makac.fs.write_file(tgt.root .. "/c.conf", "user edit\n")
	local r = run_apply_tree(root, tgt)
	t.eq(r.err, nil, "not a failure — the user broke nothing")
	t.eq(#r.out.failed, 0)
	t.eq(#r.out.changed, 0)
	t.eq(#r.out.target_only, 1)
	t.eq(r.out.target_only[1], "~/c.conf")
	t.eq(read_in(tgt, "c.conf"), "user edit\n", "target edit untouched")
	t.eq(snapshot.read(tgt, "~", "c.conf").body, "from-tree\n", "deployed record unchanged")
end)

t.case("apply: target-only + override=true takes the tree's version", function()
	local root = txtar.unpack("-- c.conf --\nfrom-tree\n")
	local tgt = new_target("apply-lo-ov")
	run_apply_tree(root, tgt)
	makac.fs.write_file(tgt.root .. "/c.conf", "user edit\n")
	local r = run_apply_tree(root, tgt, { override = true })
	t.eq(r.err, nil)
	t.eq(#r.out.failed, 0)
	t.eq(#r.out.target_only, 0)
	t.eq(#r.out.changed, 1)
	t.eq(read_in(tgt, "c.conf"), "from-tree\n", "override now means: overwrite user edits")
	t.eq(snapshot.read(tgt, "~", "c.conf").body, "from-tree\n")
end)

t.case("apply: diverged — conflict-as-data under false, overwrite under true", function()
	local root = txtar.unpack("-- c.conf --\nv1\n")
	local tgt = new_target("apply-div")
	run_apply_tree(root, tgt)
	-- BOTH move apart
	makac.fs.write_file(root .. "/c.conf", "v2\n")
	makac.fs.write_file(tgt.root .. "/c.conf", "v3\n")
	local r = run_apply_tree(root, tgt)
	t.eq(r.err, nil)
	t.eq(#r.out.failed, 1, "genuine divergence is a conflict (data)")
	t.eq(read_in(tgt, "c.conf"), "v3\n", "user edit not clobbered")
	-- with override the tree wins, and the snapshot records the new deployment
	local r2 = run_apply_tree(root, tgt, { override = true })
	t.eq(#r2.out.failed, 0)
	t.eq(#r2.out.changed, 1)
	t.eq(read_in(tgt, "c.conf"), "v2\n")
	t.eq(snapshot.read(tgt, "~", "c.conf").body, "v2\n")
end)

t.case("apply: pre-snapshot deploy keeps the 2-way conflict behavior", function()
	local root = txtar.unpack("-- c.conf --\nv1\n")
	local tgt = new_target("apply-legacy")
	run_apply_tree(root, tgt)
	-- simulate a deployment from before the snapshot existed: drop the entry
	snapshot.remove(tgt, "~", { "c.conf" })
	makac.fs.write_file(root .. "/c.conf", "v2\n")
	makac.fs.write_file(tgt.root .. "/c.conf", "v3\n")
	local r = run_apply_tree(root, tgt)
	t.eq(#r.out.failed, 1, "exists-and-differs is a conflict, as before")
	t.eq(read_in(tgt, "c.conf"), "v3\n")
end)

t.case("apply: check mode reports fast-forward, writes nothing, records nothing", function()
	local root = txtar.unpack("-- c.conf --\nv1\n")
	local tgt = new_target("apply-check-ff")
	run_apply_tree(root, tgt)
	makac.fs.write_file(root .. "/c.conf", "v2\n")
	local r = run_apply_tree(root, tgt, { check = true })
	t.eq(r.err, nil)
	t.eq(#r.out.changed, 1, "would fast-forward")
	t.eq(read_in(tgt, "c.conf"), "v1\n", "nothing written")
	t.eq(snapshot.read(tgt, "~", "c.conf").body, "v1\n", "snapshot unchanged")
	-- and a target-only edit in check mode is reported the same way
	makac.fs.write_file(tgt.root .. "/c.conf", "user edit\n")
	makac.fs.write_file(root .. "/c.conf", "user edit\n") -- source == target: converged? no — make it target-only again
	makac.fs.write_file(root .. "/c.conf", "v1\n")
	local r2 = run_apply_tree(root, tgt, { check = true })
	t.eq(#r2.out.target_only, 1, "would be reported target-only")
	t.eq(#r2.out.failed, 0)
	t.eq(read_in(tgt, "c.conf"), "user edit\n")
end)

-- ------------------------------------------------------------------ prune

local snapshot2 = snapshot
local prune = require("pkgs/dots/prune")
local action_prune = require("pkgs/dots/action_prune")

--- first return or loud test failure (for (value, err) lib calls)
local function must(v, err)
	if v == nil then t.fail(tostring(err)) end
	return v
end

--- deploy `files` (list of {rel, body}) as owner `tree` into tgt via a real
--- apply of an ephemeral tree, so the snapshot is written the way apply
--- writes it; then delete the tree from under it.
local function deploy_as(tgt, tree, files)
	local root = tostring(makac.fs.mktemp_dir("dots-test-prunesrc-"))
	for _, f in ipairs(files) do
		makac.exec({ "mkdir", "-p", "--", root .. "/" .. (f[1]:match("^(.*/)") or "") })
		makac.fs.write_file(root .. "/" .. f[1], f[2])
	end
	local ok, r = pcall(step, { uses = "dots:apply", name = "deploy", with = {
		root = root, dest = tgt.root, tree = tree, target = tgt,
	} })
	t.truthy(ok, tostring(r))
	t.eq(r.err, nil)
	makac.exec({ "rm", "-rf", root })
end

local function prune_tgt(tag)
	local tgt = new_target("prune-" .. tag)
	return tgt, tgt.root
end

t.case("prune.orphans: plan subset/superset math + owner filtering", function()
	local tgt, dest = prune_tgt("math")
	deploy_as(tgt, "mine", { { "a.conf", "a" }, { "b.conf", "b" }, { "c.conf", "c" } })
	deploy_as(tgt, "foreign", { { "other.conf", "o" } })
	-- plan is now a subset: b.conf + c.conf are orphans
	local res = must(prune.orphans(tgt, dest, "mine", { "a.conf" }))
	t.eq(#res.orphans, 2)
	t.eq(res.orphans[1].relpath, "b.conf")
	t.eq(res.orphans[2].relpath, "c.conf")
	t.eq(#res.foreign, 1)
	t.eq(res.foreign[1].tree, "foreign")
	t.eq(res.foreign[1].count, 1)
	-- a superset (extra planned relpaths) yields NO orphans and still sees
	-- nothing of the foreign tree
	local res2 = must(prune.orphans(tgt, dest, "mine",
		{ "a.conf", "b.conf", "c.conf", "x.conf" }))
	t.eq(#res2.orphans, 0)
	-- asking as the FOREIGN owner flips the picture
	local res3 = must(prune.orphans(tgt, dest, "foreign", { "other.conf" }))
	t.eq(#res3.orphans, 0)
	t.eq(res3.foreign[1].tree, "mine")
	t.eq(res3.foreign[1].count, 3)
end)

t.case("prune.orphans: drifted + vanished flags, link repointing", function()
	local tgt, dest = prune_tgt("flags")
	deploy_as(tgt, "mine", { { "drift.conf", "deployed" }, { "stable.conf", "stable" } })
	makac.fs.write_file(tgt.root .. "/drift.conf", "user edited") -- target-only drift
	makac.exec({ "rm", "-f", tgt.root .. "/stable.conf" })         -- vanished
	-- a link entry: deployed via with.files + tree so the snapshot tracks it
	local ok, r = pcall(step, { uses = "dots:link", name = "l", with = {
		dest = tgt.root .. "/alias", link = "app/config", target = tgt,
	} })
	t.truthy(ok, tostring(r))
	snapshot2.write(tgt, dest, "alias", { tree = "mine", kind = "link" }, "app/config")
	-- a second link that gets REPOINTED by the user
	snapshot2.write(tgt, dest, "alias2", { tree = "mine", kind = "link" }, "app/config")
	makac.exec({ "ln", "-sfn", "--", "elsewhere", tgt.root .. "/alias2" })
	local res = must(prune.orphans(tgt, dest, "mine", {}))
	local by = {}
	for _, o in ipairs(res.orphans) do by[o.relpath] = o end
	t.eq(by["drift.conf"].drifted, true)
	t.eq(by["drift.conf"].target_kind, "file")
	t.eq(by["stable.conf"].target_kind, nil, "vanished")
	t.eq(by["stable.conf"].drifted, false)
	t.eq(by["alias"].drifted, false, "link unchanged")
	t.eq(by["alias"].target_kind, "link")
	t.eq(by["alias2"].drifted, true, "repointed link is drifted")
end)

t.case("prune: dir entries — vanished forget, empty rmdir, non-empty kept", function()
	local tgt, dest = prune_tgt("dirs")
	deploy_as(tgt, "mine", { { "a.conf", "a" } })
	local function dirsnap(rel, extra)
		local meta = { tree = "mine", kind = "dir" }
		for k, v in pairs(extra or {}) do meta[k] = v end
		snapshot2.write(tgt, dest, rel, meta, "")
	end
	dirsnap("gone-dir")                       -- target counterpart vanished
	dirsnap("empty-dir", { mode = "0750" }) -- exists, empty, attrs in record
	dirsnap("busy-dir")                      -- exists, non-empty
	makac.exec({ "mkdir", tgt.root .. "/empty-dir" })
	makac.exec({ "chmod", "700", tgt.root .. "/empty-dir" }) -- attr drift
	makac.exec({ "mkdir", tgt.root .. "/busy-dir" })
	makac.fs.write_file(tgt.root .. "/busy-dir/keep.conf", "keep")

	local res = must(prune.orphans(tgt, dest, "mine", {}))
	local by = {}
	for _, o in ipairs(res.orphans) do by[o.relpath] = o end
	t.eq(by["gone-dir"].target_kind, nil, "vanished dir orphan")
	t.eq(by["empty-dir"].empty, true)
	t.eq(by["empty-dir"].drifted, true, "mode drift on the recorded attrs")
	t.eq(by["busy-dir"].empty, false)
	t.eq(by["busy-dir"].drifted, false)

	-- decision: vanished → entry dropped; empty → rmdir + entry dropped;
	-- non-empty → loud refusal, dir AND entry survive
	local d1 = must(prune.apply_decision(tgt, dest, by["gone-dir"], "delete"))
	t.eq(d1.removed_live, false)
	local d2 = must(prune.apply_decision(tgt, dest, by["empty-dir"], "delete"))
	t.eq(d2.removed_live, true)
	t.eq(makac.fs.stat(tgt.root .. "/empty-dir"), nil, "empty dir rmdir'd")
	local d3, d3err = prune.apply_decision(tgt, dest, by["busy-dir"], "delete")
	t.eq(d3, nil)
	t.truthy(tostring(d3err):match("not empty"))
	t.truthy(makac.fs.stat(tgt.root .. "/busy-dir") ~= nil, "non-empty dir survives")
	t.truthy(select(1, snapshot2.read(tgt, dest, "busy-dir")) ~= nil,
		"its snapshot entry survives too")
	-- forget works for dirs as for files
	must(prune.apply_decision(tgt, dest, by["busy-dir"], "forget"))
	t.truthy(select(1, snapshot2.read(tgt, dest, "busy-dir")) == nil)
	t.truthy(makac.fs.stat(tgt.root .. "/busy-dir") ~= nil, "forget never removes")
end)

t.case("prune.apply_decision: delete removes target + entry; forget keeps target", function()
	local tgt, dest = prune_tgt("decide")
	deploy_as(tgt, "mine", { { "gone.conf", "g" }, { "kept.conf", "k" } })
	local res = must(prune.orphans(tgt, dest, "mine", {}))
	local by = {}
	for _, o in ipairs(res.orphans) do by[o.relpath] = o end
	local d = must(prune.apply_decision(tgt, dest, by["gone.conf"], "delete"))
	t.eq(d.removed_live, true)
	t.eq(read_in(tgt, "gone.conf"), nil, "target file removed")
	t.eq(select(1, snapshot2.read(tgt, dest, "gone.conf")), nil, "entry dropped")
	local f = must(prune.apply_decision(tgt, dest, by["kept.conf"], "forget"))
	t.eq(f.removed_live, false)
	t.eq(read_in(tgt, "kept.conf"), "k", "forget leaves the target file")
	t.eq(select(1, snapshot2.read(tgt, dest, "kept.conf")), nil, "entry dropped")
end)

t.case("prune.apply_decision: never removes directories", function()
	local tgt, dest = prune_tgt("danguard")
	deploy_as(tgt, "mine", { { "sub/f.conf", "f" } })
	-- the deployed FILE was replaced by a DIRECTORY on the target side
	makac.exec({ "rm", "-f", tgt.root .. "/sub/f.conf" })
	makac.exec({ "mkdir", tgt.root .. "/sub/f.conf" })
	local res = must(prune.orphans(tgt, dest, "mine", {}))
	local o = res.orphans[1]
	t.eq(o.target_kind, "dir")
	t.eq(o.drifted, true)
	local d, derr = prune.apply_decision(tgt, dest, o, "delete")
	t.eq(d, nil)
	t.truthy(tostring(derr):match("directory"))
	t.truthy(makac.fs.stat(tgt.root .. "/sub/f.conf") ~= nil, "dir still there")
	-- the SNAPSHOT entry also survives a refused delete
	t.truthy(select(1, snapshot2.read(tgt, dest, "sub/f.conf")) ~= nil)
end)

-- ............................................................. dots:prune

local function run_prune(with)
	local ok, r = pcall(step, { uses = "dots:prune", name = "prune", with = with })
	t.truthy(ok, tostring(r))
	return r
end

t.case("dots:prune: report is the default and mutates nothing", function()
	local tgt = new_target("prune-act-report")
	local root = txtar.unpack([==[-- a.conf --
a
-- b.conf --
b
]==])
	-- deploy a 3-file tree, then drop one file from the tree
	makac.fs.write_file(root .. "/gone.conf", "g")
	run_apply_tree(root, tgt)
	makac.exec({ "rm", "-f", root .. "/gone.conf" })
	local r = run_prune({ root = root, dest = tgt.root, target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, false, "report changes nothing")
	t.eq(#r.out.would_delete, 1)
	t.eq(r.out.would_delete[1].relpath, "gone.conf")
	t.eq(#r.out.would_forget, 0)
	t.eq(read_in(tgt, "gone.conf"), "g", "target file intact")
	t.truthy(select(1, snapshot.read(tgt, tgt.root, "gone.conf")) ~= nil, "entry intact")
	-- check=true reports identically even under an explicit delete policy
	local r2 = run_prune({ root = root, dest = tgt.root, target = tgt,
		policy = "delete", check = true })
	t.eq(r2.changed, false)
	t.eq(#r2.out.would_delete, 1)
	t.eq(read_in(tgt, "gone.conf"), "g", "still intact")
end)

t.case("dots:prune: delete removes orphans, auto-forgets the vanished", function()
	local tgt = new_target("prune-act-delete")
	local root = txtar.unpack("-- a.conf --\na\n")
	makac.fs.write_file(root .. "/old.conf", "old")
	makac.fs.write_file(root .. "/stale.conf", "stale")
	run_apply_tree(root, tgt)
	makac.exec({ "rm", "-f", root .. "/old.conf", root .. "/stale.conf" })
	-- stale.conf: the user already deleted the LIVE file by hand
	makac.exec({ "rm", "-f", tgt.root .. "/stale.conf" })
	local r = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "delete" })
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(#r.out.deleted, 1)
	t.eq(r.out.deleted[1].relpath, "old.conf")
	t.eq(#r.out.forgotten, 1)
	t.eq(r.out.forgotten[1], "stale.conf")
	t.eq(r.out.vanished[1], "stale.conf")
	t.eq(#r.out.failed, 0)
	t.eq(read_in(tgt, "old.conf"), nil, "orphan deleted")
	t.eq(read_in(tgt, "a.conf"), "a\n", "planned file untouched")
	t.truthy(select(1, snapshot.read(tgt, tgt.root, "a.conf")) ~= nil,
		"planned file's entry still tracked")
	t.eq(select(1, snapshot.read(tgt, tgt.root, "old.conf")), nil,
		"orphan entry dropped")
end)

t.case("dots:prune: forget drops entries but leaves target files", function()
	local tgt = new_target("prune-act-forget")
	local root = txtar.unpack("-- a.conf --\na\n")
	makac.fs.write_file(root .. "/old.conf", "old")
	run_apply_tree(root, tgt)
	makac.exec({ "rm", "-f", root .. "/old.conf" })
	local r = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "forget" })
	t.eq(#r.out.forgotten, 1)
	t.eq(r.out.forgotten[1], "old.conf")
	t.eq(read_in(tgt, "old.conf"), "old", "target file stays")
	t.eq(select(1, snapshot.read(tgt, tgt.root, "old.conf")), nil, "entry gone")
	-- second prune run: nothing left to report
	local r2 = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "forget" })
	t.eq(r2.changed, false)
	t.eq(#r2.out.forgotten, 0)
end)

t.case("dots:prune: drift is reported but delete proceeds", function()
	local tgt = new_target("prune-act-drift")
	local root = txtar.unpack("-- a.conf --\na\n")
	makac.fs.write_file(root .. "/old.conf", "deployed")
	run_apply_tree(root, tgt)
	makac.exec({ "rm", "-f", root .. "/old.conf" })
	makac.fs.write_file(tgt.root .. "/old.conf", "user edited after deploy")
	local r = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "delete" })
	t.eq(#r.out.deleted, 1)
	t.eq(r.out.deleted[1].drifted, true, "drift flag surfaces in the report")
	t.eq(read_in(tgt, "old.conf"), nil, "explicit policy wins over drift")
end)

t.case("dots:prune: foreign entries are reported, never touched", function()
	local tgt = new_target("prune-act-foreign")
	local root = txtar.unpack("-- a.conf --\na\n")
	run_apply_tree(root, tgt)
	-- a foreign tree deployed (and later un-planned) its own file
	deploy_as(tgt, "bootstrap", { { "foreign.conf", "f" } })
	snapshot.write(tgt, tgt.root, "gone-foreign.conf",
		{ tree = "bootstrap", kind = "file" }, "x")
	local r = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "delete" })
	t.eq(r.err, nil)
	t.eq(#r.out.deleted, 0)
	t.eq(#r.out.forgotten, 0)
	t.eq(#r.out.foreign, 1)
	t.eq(r.out.foreign[1].tree, "bootstrap")
	t.eq(r.out.foreign[1].count, 2, "foreign file + foreign stale entry")
	t.eq(read_in(tgt, "foreign.conf"), "f", "foreign target file untouched")
	t.truthy(select(1, snapshot.read(tgt, tgt.root, "gone-foreign.conf")) ~= nil,
		"foreign snapshot entry untouched")
end)

t.case("dots:prune: validation + strict failure semantics", function()
	local tgt = new_target("prune-act-val")
	local r = action_prune.prune({})
	t.truthy(r.err and r.err:match("'root'"))
	t.truthy(action_prune.prune({ root = "/x", policy = "bogus" }).err:match("'policy'"))
	-- strict: a per-orphan failure becomes err (failure engineered via a
	-- directory standing where a deployed FILE used to be)
	local root = txtar.unpack("-- a.conf --\na\n")
	makac.fs.write_file(root .. "/old.conf", "old")
	run_apply_tree(root, tgt)
	makac.exec({ "rm", "-f", root .. "/old.conf", tgt.root .. "/old.conf" })
	makac.exec({ "mkdir", tgt.root .. "/old.conf" }) -- target orphan became a dir
	local r2 = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "delete" })
	t.eq(r2.err, nil, "non-strict: failure is data")
	t.eq(#r2.out.failed, 1)
	local r3 = action_prune.prune({ root = root, dest = tgt.root, target = tgt,
		policy = "delete", strict = true })
	t.truthy(r3.err and r3.err:match("strict"))
end)

-- ---------------------------------------------------- directory attrs + dots:dir

local action_dir = require("pkgs/dots/action_dir")

t.case("walk: ['.'] dir entries emit BEFORE their children (depth-first)", function()
	local root = txtar.unpack([==[-- dots.lua --
return { ["."] = { mode = "0700" } }
-- app/dots.lua --
return { ["."] = { mode = "0755" } }
-- app/f.conf --
f
-- top.conf --
t
]==])
	local entries = plan.tree(root, { dest = "~" })
	local idx = {}
	for i, e in ipairs(entries) do idx[e.dest] = i end
	t.truthy(idx["~"], "root ['.'] entry emitted")
	t.eq(entries[idx["~"]].dir, true)
	t.eq(entries[idx["~"]].relpath, ".", "root dir relpath is the documented '.'")
	t.eq(entries[idx["~"]].mode, "0700")
	t.truthy(idx["~"] < idx["~/app"], "root dir before its child dir")
	t.truthy(idx["~/app"] < idx["~/app/f.conf"], "dir entry before its children")
	t.truthy(idx["~"] < idx["~/top.conf"], "root dir before its files")
	local app = entries[idx["~/app"]]
	t.eq(app.dir, true)
	t.eq(app.relpath, "app")
	t.eq(app.mode, "0755")
end)

t.case("walk: ['.'] validation — only mode/owner/skip allowed", function()
	local function walk_err(dotslua)
		local root = tostring(makac.fs.mktemp_dir("dots-test-"))
		makac.fs.write_file(root .. "/dots.lua", dotslua)
		makac.fs.write_file(root .. "/f.conf", "f\n")
		local ok, err = pcall(plan.tree, root)
		return ok, err
	end
	for _, key in ipairs({ "renderer = function(c) return c end", "content = 'x'",
		"src = 'f.conf'", "link = 'x'", "absent = true" }) do
		local ok, err = walk_err("return { ['.'] = { " .. key .. " } }")
		t.eq(ok, false, "['.'] with " .. key)
		t.truthy(tostring(err):match("mode/owner/skip"), tostring(err))
	end
	local ok, err = walk_err("return { ['.'] = { mode = '0700', owner = 'u:g', skip = true } }")
		t.truthy(ok, tostring(err))
	local ok2, err2 = walk_err("return { ['.'] = 'nope' }")
	t.eq(ok2, false)
end)

t.case("walk: $default_attrs never fills dir entries", function()
	local root = txtar.unpack([==[-- dots.lua --
return {
	["$default_attrs"] = { mode = "0600", owner = "u:g" },
	["."] = {},
}
-- sub/dots.lua --
return { ["."] = { mode = "0700" } }
-- f.conf --
f
-- sub/g.conf --
g
]==])
	local m = by_dest(plan.tree(root))
	t.eq(m["~"].dir, true)
	t.eq(m["~"].mode, nil, "empty ['.']: $default_attrs did not leak onto the dir entry")
	t.eq(m["~/sub"].mode, "0700", "explicit dir attrs win...")
	t.eq(m["~/sub"].owner, nil, "...and nothing else fills in")
	t.eq(m["~/f.conf"].mode, "0600", "files still get $default_attrs")
end)

t.case("dots:dir: mkdir -p leaf+gap, refuse non-dir, mode drift, check", function()
	local tgt = new_target("dir-prim")
	-- bare dots:dir with an explicit dest needs no gate — the dest IS the ack
	local r = action_dir.dir({ dest = tgt.root .. "/a/b/c", mode = "0750", target = tgt })
	t.eq(r.err, nil)
	t.eq(r.changed, true)
	t.eq(mode_of(tgt.root .. "/a/b/c"), "750")
	t.eq(mode_of(tgt.root .. "/a/b"), "755", "unmanaged gap dirs keep umask defaults")
	-- converged
	local r2 = action_dir.dir({ dest = tgt.root .. "/a/b/c", mode = "0750", target = tgt })
	t.eq(r2.err, nil)
	t.eq(r2.changed, false)
	-- mode drift applies
	makac.exec({ "chmod", "777", tgt.root .. "/a/b/c" })
	local r3 = action_dir.dir({ dest = tgt.root .. "/a/b/c", mode = "0750", target = tgt })
	t.eq(r3.changed, true)
	t.eq(mode_of(tgt.root .. "/a/b/c"), "750")
	-- refuses a non-dir node, loudly
	makac.fs.write_file(tgt.root .. "/a-b-file", "x")
	local r4 = action_dir.dir({ dest = tgt.root .. "/a-b-file", target = tgt })
	t.truthy(r4.err and r4.err:match("refusing to replace it with a directory"))
	-- check mode writes nothing
	local r5 = action_dir.dir({ dest = tgt.root .. "/never-made", mode = "0700",
		target = tgt, check = true })
	t.eq(r5.changed, true)
	t.eq(makac.fs.stat(tgt.root .. "/never-made"), nil, "check made nothing")
	local r6 = action_dir.dir({ dest = tgt.root .. "/a/b/c", mode = "0700", target = tgt, check = true })
	t.eq(r6.changed, true, "check reports pending drift")
	t.eq(mode_of(tgt.root .. "/a/b/c"), "750", "check applied nothing")
	-- file-entry keys are rejected
	t.truthy(action_dir.dir({ dest = tgt.root .. "/x", content = "x" }).err)
	t.truthy(action_dir.dir({ dest = tgt.root .. "/x", link = "y" }).err)
end)

t.case("apply: dir entries land before files, snapshot kind=dir is recorded", function()
	local tgt = new_target("dir-apply")
	local root = txtar.unpack([==[-- dots.lua --
return {}
-- app/dots.lua --
return { ["."] = { mode = "0700" } }
-- app/f.conf --
f
]==])
	local r = run_apply_tree(root, tgt, {})
	t.eq(r.err, nil)
	t.eq(#r.out.failed, 0)
	t.eq(mode_of(tgt.root .. "/app"), "700", "dir mode applied before files land")
	t.eq(read_in(tgt, "app/f.conf"), "f\n")
	local en = must(snapshot.read(tgt, "~", "app"))
	t.eq(en.meta.kind, "dir")
	t.eq(en.meta.mode, "0700")
	t.eq(en.body, "", "dir entries carry no body")
	-- converged re-run: ok, no change
	local r2 = run_apply_tree(root, tgt, {})
	t.eq(#r2.out.changed, 0)
end)

t.case("apply: root ['.'] needs manage_dest_dir (the DEST footgun gate)", function()
	local tgt = new_target("dir-gate")
	local root = txtar.unpack([==[-- dots.lua --
return { ["."] = { mode = "0777" } }
-- f.conf --
f
]==])
	-- without the flag: the root dir entry fails LOUDLY (footgun explained),
	-- files still deploy; dest root mode is untouched
	local mode_before = mode_of(tgt.root)
	local r = run_apply_tree(root, tgt, {})
	t.eq(r.err, nil, "non-strict: the gated failure is data")
	t.eq(#r.out.failed, 1)
	t.truthy(r.out.failed[1].err:match("manage_dest_dir"), r.out.failed[1].err)
	t.eq(read_in(tgt, "f.conf"), "f\n")
	t.eq(mode_of(tgt.root), mode_before, "dest root mode untouched")
	-- with the flag: applied + snapshot recorded for relpath "."
	local r2 = run_apply_tree(root, tgt, { manage_dest_dir = true })
	t.eq(#r2.out.failed, 0)
	t.eq(mode_of(tgt.root), "777")
	local en = must(snapshot.read(tgt, "~", "."))
	t.eq(en.meta.kind, "dir")
	t.eq(en.meta.mode, "0777")
end)

t.case("dots:diff: dir drift is MODE/OWNER lines, never a content diff", function()
	local tgt = new_target("dir-diff")
	-- target state by hand (the tree asks for an owner that does not exist
	-- here — an apply would fail on chown; diff only ever READS)
	makac.exec({ "mkdir", tgt.root .. "/app" })
	makac.fs.write_file(tgt.root .. "/app/f.conf", "f\n")
	local root = txtar.unpack([==[-- app/dots.lua --
return { ["."] = { mode = "0700", owner = "no-such-user-xyz:no-such-group-xyz" } }
-- app/f.conf --
f
]==])
	local r = action_diff.diff({ root = root, dest = tgt.root, target = tgt })
	t.eq(r.err, nil)
	t.eq(#r.out.mode_drift, 1)
	t.eq(r.out.mode_drift[1], tgt.root .. "/app")
	t.eq(#r.out.owner_drift, 1)
	t.eq(#r.out.differing, 0, "dirs never produce content diffs")
	local libdiff = require("pkgs/dots/diff")
	local text = libdiff.render(r.out.entries)
	t.truthy(text:match("MODE .*/app: 755 %-> 0700"), text)
	t.truthy(text:match("OWNER .*/app: .+ %-> no%-such%-user%-xyz:no%-such%-group%-xyz"), text)
end)

t.case("dots:prune: orphaned dirs — empty rmdir'd, non-empty kept+reported", function()
	local tgt = new_target("dir-prune-act")
	local root = txtar.unpack([==[-- emptyd/dots.lua --
return { ["."] = {} }
-- emptyd/f.conf --
f
-- busyd/dots.lua --
return { ["."] = {} }
-- busyd/g.conf --
g
]==])
	run_apply_tree(root, tgt, {})
	-- dirs leave the tree entirely; emptyd's contents were user-deleted by
	-- hand (its file orphan is auto-forgotten, the dir itself is EMPTY now),
	-- busyd still holds a target file
	makac.exec({ "rm", "-rf", root .. "/emptyd", root .. "/busyd" })
	makac.exec({ "rm", "-f", tgt.root .. "/emptyd/f.conf" })
	local r = run_prune({ root = root, dest = tgt.root, target = tgt, policy = "delete" })
	t.eq(r.err, nil)
	local deleted = {}
	for _, d in ipairs(r.out.deleted) do deleted[d.relpath] = true end
	t.truthy(deleted["emptyd"], "empty orphaned dir rmdir'd")
	t.truthy(deleted["busyd/g.conf"], "orphaned file inside busyd deleted")
	t.eq(r.out.skipped_dirs[1], "busyd", "non-empty dir kept + reported")
	t.eq(makac.fs.stat(tgt.root .. "/busyd") ~= nil, true, "non-empty dir still there")
	t.eq(makac.fs.stat(tgt.root .. "/emptyd"), nil, "empty dir gone")
	-- its snapshot entry dropped; busyd's kept for next time
	t.eq(select(1, snapshot.read(tgt, tgt.root, "emptyd")), nil)
	t.truthy(select(1, snapshot.read(tgt, tgt.root, "busyd")) ~= nil)
end)

-- -------------------------------------- merge3 (integration machinery, runner-side)

local merge3 = require("pkgs/dots/merge3")

t.case("merge3: clean merge of disjoint edits", function()
	local r = must(merge3.merge("a\nb\nc\n", "a\nLIVE-b\nc\n", "a\nb\nc\nSRC\n"))
	t.eq(r.clean, true)
	t.eq(r.result, "a\nLIVE-b\nc\nSRC\n", "both edits survive")
end)

t.case("merge3: single conflict, LABELED markers", function()
	local r = must(merge3.merge("a\nb\nc\n", "a\nL\nc\n", "a\nS\nc\n"))
	t.eq(r.clean, false)
	t.truthy(r.marked:match("<<<<<<< Untracked Changes"), "target label present")
	t.truthy(r.marked:match("||||||| Old"), "base label present")
	t.truthy(r.marked:match(">>>>>>> New"), "source label present")
	-- exact layout: target section first, then base, then source, then close
	t.eq(r.marked, "a\n<<<<<<< Untracked Changes\nL\n||||||| Old\nb\n=======\nS\n>>>>>>> New\nc\n")
	t.eq(#r.conflicts, 1)
	t.eq(r.conflicts[1].start_line, 2)
	t.eq(r.conflicts[1].end_line, 8)
	t.eq(table.concat(r.conflicts[1].target, "\n"), "L")
	t.eq(table.concat(r.conflicts[1].base, "\n"), "b")
	t.eq(table.concat(r.conflicts[1].new, "\n"), "S")
end)

t.case("merge3: multiple conflicts are all reported", function()
	local base = "1\n2\n3\n4\n5\n6\n7\n"
	local target = "1\nL2\n3\n4\n5\nL6\n7\n"
	local src = "1\nS2\n3\n4\n5\nS6\n7\n"
	local r = must(merge3.merge(base, target, src))
	t.eq(r.clean, false)
	t.eq(#r.conflicts, 2, "both overlapping edits conflict")
end)

t.case("merge3: both-sides-identical is a clean no-op", function()
	local r = must(merge3.merge("same\n", "same\n", "same\n"))
	t.eq(r.clean, true)
	t.eq(r.result, "same\n")
	-- target untouched, only the source moved (a fast-forward shape)
	local r2 = must(merge3.merge("base\n", "base\n", "new source\n"))
	t.eq(r2.clean, true)
	t.eq(r2.result, "new source\n")
	-- both sides made the SAME edit: not a conflict
	local r3 = must(merge3.merge("base\n", "same-edit\n", "same-edit\n"))
	t.eq(r3.clean, true)
	t.eq(r3.result, "same-edit\n")
end)

t.case("merge3: missing trailing newline survives round trips", function()
	-- all inputs end without a newline; only the source moved
	local r = must(merge3.merge("x\ny", "x\ny", "x\ny\nz"))
	t.eq(r.clean, true)
	t.eq(r.result, "x\ny\nz", "diff3 must not append a trailing newline")
	-- identical inputs, no trailing newline anywhere
	local r2 = must(merge3.merge("a\nb", "a\nb", "a\nb"))
	t.eq(r2.clean, true)
	t.eq(r2.result, "a\nb")
	-- empty EVERYTHING is a lawful, clean no-op
	local r3 = must(merge3.merge("", "", ""))
	t.eq(r3.clean, true)
	t.eq(r3.result, "")
end)

t.case("merge3.validate_no_markers: clean text passes, leftovers are located", function()
	t.eq(merge3.validate_no_markers("a\nb\nc\n"), true)
	-- a stray "====="-run that is NOT exactly seven is fine
	t.eq(merge3.validate_no_markers("a\n==========\nc\n"), true)
	local edited =
		"a\n"
		.. "<<<<<<< custom label tolerated\n"
		.. "mine\n"
		.. "=======\n"
		.. "theirs\n"
		.. ">>>>>>> any label\n"
		.. "b\n"
		.. "=======\n" -- stray separator, no conflict around it
		.. "c\n"
	local ok, ranges = merge3.validate_no_markers(edited)
	t.eq(ok, nil)
	t.eq(#ranges, 2)
	t.eq(ranges[1].start_line, 2)
	t.eq(ranges[1].end_line, 6)
	t.eq(ranges[2].start_line, 8)
	t.eq(ranges[2].end_line, 8, "stray marker is its own range")
	-- resolved text (markers edited away) validates clean
	t.eq(merge3.validate_no_markers("a\nmine\nb\nc\n"), true)
end)

t.case("merge3.parse_conflicts: regions and surrounding split", function()
	local marked = "top\n<<<<<<< Untracked Changes\nL1\nL2\n||||||| Old\nB\n=======\nN\n>>>>>>> New\nbottom\n"
	local p = merge3.parse_conflicts(marked)
	t.eq(#p.regions, 1)
	local r = p.regions[1]
	t.eq(table.concat(r.target, "|"), "L1|L2")
	t.eq(table.concat(r.base, "|"), "B")
	t.eq(table.concat(r.new, "|"), "N")
	t.eq(p.surrounding, "top\nbottom", "non-conflict text, reporting aid")
	t.eq(#merge3.parse_conflicts("no markers here\n").regions, 0)
end)

t.case("merge3: binary input is refused (never a garbage text merge)", function()
	local r, err = merge3.merge("a\0b", "a\0b", "c")
	t.eq(r, nil)
	t.truthy(tostring(err):match("binary"))
	local r2, err2 = merge3.merge("a\n", "b\n\0", "a\n")
	t.eq(r2, nil)
	t.truthy(tostring(err2):match("target"), tostring(err2))
end)

t.case("merge3: non-string arguments are a loud (nil, err)", function()
	local r, err = merge3.merge(nil, "a", "a")
	t.eq(r, nil)
	t.truthy(tostring(err):match("base must be a string"))
end)

t.done()
