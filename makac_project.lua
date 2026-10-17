-- makac_project.lua — this project's dependency wiring.
--
-- makac.dots wires ITSELF in place via the filesystem fetcher (the local-
-- development pattern; cf. nvme-check's testlib): this is what makes
-- `dots:file`/`dots:link`/`dots:apply` usable from this repo's own
-- workflows (workflows/example.lua, tests) and what lets `makac doctor`
-- run the package's health.lua here.
--
-- Downstream projects instead pin a revision:
--
--   return {
--     inputs = {
--       dots = { fetcher = "fetchgit",
--         with = { url = "https://github.com/jwdevantier/makac.dots",
--                  rev = "<commit>" } },
--     },
--     packages = { dots = "dots" },
--   }
return {
	inputs = { dots = { fetcher = "filesystem", with = { path = "." } } },
	packages = { dots = "dots" },
}
