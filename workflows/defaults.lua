-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- workflows/defaults.lua — shared attribute sets and renderers for the
-- example tree. Lives OUTSIDE the tree, next to the workflow; the tree's
-- dots.lua files pull it in with `dofile(PROJECT_DIR .. "/...")`.
--
-- Renderer inputs must be explicit and stable — the rendered output is what
-- gets hashed, so a nondeterministic input (timestamp, hostname) manifests
-- as spurious `changed` on every run.

return {
	-- $default_attrs for the example tree: every shipped file is private
	files = { mode = "0600" },

	-- gitconfig templating without a template language: a renderer is any
	-- pure function(content) -> string
	render_gitconfig = function(content)
		local user = os.getenv("USER") or "nobody"
		return (content:gsub("@DOTS_EXAMPLE_USER@", user))
	end,
}
