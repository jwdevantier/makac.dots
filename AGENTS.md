
This project will be an extension/package for Makac an orchestrator/runner which is
a bit like Github Actions workflows (in that there's a focus on high-level actions),
meets Ansible (in the sense that actions should describe/declare a desired end-state,
and that their running will report success/failure/skipped, but also changed (bool)),
but where workflows are written in Lua instead of YAML, and therefore the full power
of Lua 5.4 (loops, conditionals, modules, ...) can be leveraged when writing workflows.


## Sources
- Makac: ~/repos/makac  (source-code)
- Makac docs: ~/repos/makac/site/src  (user-facing documentation, describes the whole system)

- Makac.qemu: (example of how to make a makac package, note the makac_package.lua file etc)
    Source: ~/repos/makac.qemu
    Documentation: ~/repos/makac.qemu ,, in git branch 'docs'

- nvme-check: (project using makac AND makac.qemu, but which layers a pytest-like UI on top, for writing tests of various kinds which use makac and makac.qemu to build VM images, boot VMs, communicate to VMs over SSH etc)
    Source: ~/repos/nvme-check
