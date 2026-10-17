-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- lib/bbctx.lua — dots-specific case helpers on top of the harness context:
-- building throwaway test projects that pin makac.dots in place (filesystem
-- fetcher), writing source trees from nested Lua tables, and quoting paths
-- into generated workflow sources.
--
-- Hermeticity rules (mirroring ~/repos/makac/tests/blackbox/README.md): no
-- network, nothing outside the per-case tmp dir; the ONLY package wiring is
-- the in-place pin of this very repository; destinations of test workflows
-- are inside the tmp dir (or under HOME=ctx.tmp via '~'), never the real
-- home directory.

local bb = {}

-- the package under test, pinned in place (load-in-place development
-- pattern — see ~/repos/nvme-check/makac_project.lua)
bb.DOTS = "/home/nixos/repos/makac.dots"

--- Lua-quoting a string for embedding into generated workflow sources.
function bb.q(s)
	return string.format("%q", s)
end

--- Write <tmp>/<path> creating parent dirs first.
function bb.writef(ctx, path, body)
	makac.fs.mkdir_p((ctx.path(path):gsub("/[^/]*$", "")))
	makac.fs.write_file(ctx.path(path), body)
end

--- Materialize a nested table into directories/files under <tmp>/<rel>:
--- string values become file bodies, table values become subdirectories.
function bb.tree(ctx, rel, spec)
	for name, v in pairs(spec) do
		local p = rel .. "/" .. name
		if type(v) == "string" then
			bb.writef(ctx, p, v)
		elseif type(v) == "table" then
			ctx.mkdir_p(p)
			bb.tree(ctx, p, v)
		else
			error("tree spec: unsupported value type " .. type(v) .. " at " .. p)
		end
	end
end

--- Build a throwaway project at <tmp>/<name> wired to this repo:
---   { .makac/, makac_project.lua pinning makac.dots in place, tree/ =
---     treespec materialized, returns the project path }.
--- The filesystem fetcher loads in place — no `makac fetch` needed.
--- Workflows are written per-case afterwards (bb.writef(ctx, name .. "/w.lua",
--- ...)) and run with chdir = the returned path.
function bb.make_project(ctx, name, treespec)
	local h = require("harness")
	h.eq(ctx.run({ "init", ctx.path(name) }).code, 0, "makac init " .. name)
	ctx.write(name .. "/makac_project.lua", ([[
return {
  inputs = { dots = { fetcher = "filesystem", with = { path = %s } } },
  packages = { dots = "dots" },
}
]]):format(bb.q(bb.DOTS)))
	if treespec then
		bb.tree(ctx, name .. "/tree", treespec)
	end
	return ctx.path(name)
end

return bb
