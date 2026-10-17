#!/usr/bin/env makac
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- tests/blackbox/run.lua — black-box test suite for makac.dots, driving a
-- makac binary purely through its CLI. Modeled on (and self-contained like)
-- ~/repos/makac/tests/blackbox — see that README for the conventions:
-- hermetic per-case tmp dirs, NO_COLOR=1, step timings normalized.
--
--   makac tests/blackbox/run.lua [binary-under-test]
--
-- binary-under-test: absolute path or PATH name (default: the fresh zig
-- build at ~/repos/makac/zig-out/bin/makac; also settable via MAKAC_BIN).

package.path = SCRIPT_DIR .. "/lib/?.lua;"
	.. SCRIPT_DIR .. "/cases/?.lua;" .. package.path

local harness = require("harness")

-- resolve the binary under test to an absolute path (ctx.run chdir's the
-- child into a throwaway tmp dir, so a relative argv[0] would not survive).
local function resolve(bin)
	if bin:find("/", 1, true) then
		if bin:sub(1, 1) == "/" then return bin end
		local pwd = (makac.exec({ "pwd" }).stdout or ""):gsub("%s+$", "")
		if pwd == "" then error("cannot determine cwd to resolve binary: " .. bin) end
		return pwd .. "/" .. bin
	end
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = dir .. "/" .. bin
		local st = makac.fs.stat(p) -- lstat: accept plain files and symlinks
		if st and (st.type == "file" or st.type == "link") then return p end
	end
	error("binary not found on PATH: " .. bin)
end

local binarg = arg[1]
if binarg == "--" then binarg = arg[2] end -- tolerate a stray separator
local bin = resolve(binarg or os.getenv("MAKAC_BIN") or "/home/nixos/repos/makac/zig-out/bin/makac")
print("# testing: " .. bin)

require("file")
require("apply")
require("ssh_real") -- needs jwd@workpc.lan; skips itself when unreachable

harness.main(bin)
