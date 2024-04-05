package = "dt-git-annex"
version = "dev-1"
source = {
   url = "git+https://github.com/micharambou/darktable-git-annex.git"
}
description = {
   summary = "This integrates [git annex][] into [darktable][], using the following workflow:",
   detailed = "This integrates [git annex][] into [darktable][], using the following workflow:",
   homepage = "https://github.com/micharambou/darktable-git-annex",
   license = "*** please specify a license ***"
}
build = {
   type = "builtin",
   modules = {
      ["git-annex"] = "git-annex.lua"
   }
}
