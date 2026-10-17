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
	t.eq(#makac.fs.listdir(tgt.root), 2, "exactly the tree's two top-level dirs, nothing stray")
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
	["$override"] = function(name) return name:match("%.local$") ~= nil end,
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

t.case("tree: load_dotsfile, and dots.lua using PROJECT_DIR", function()
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
	-- check still counts a conflict as a failure (state cannot converge)
	makac.fs.write_file(tgt.root .. "/a.conf", "local edit")
	local r3 = action_apply.apply({ root = root, target = tgt, check = true })
	t.eq(r3.err, nil)
	t.eq(#r3.out.failed, 1)
	t.eq(read_in(tgt, "a.conf"), "local edit", "check wrote nothing")
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
	-- absent-removal records the removed path (removals are journalled too:
	-- 'paths this package has written')
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
