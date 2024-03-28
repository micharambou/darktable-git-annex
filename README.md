git annex darktable integration
===============================

This integrates [git annex][] into [darktable][], using the following workflow:

* The photos you wish to use this for must already be in an initialized git
  annex repository. They don't need to be added, however.
* Tags are automatically added to files, to reflect the git annex state in
  darktable. These tags are:

    * git-annex|here
    * git-annex|dropped
    * git-annex|annexed

This plugin creates shortcuts that can be bound to keys. You can find these
shortcuts in the settings → shortcuts → lua menu. I recommend the following
configuration:

* git annex: add images `<Primary><Shift>plus`
* git annex: drop images `<Primary>minus`
* git annex: get images `<Primary>equal`

Installation
------------

### Using script_manager

* open `action` `install/update scripts`
* in the URL box enter `https://github.com/micharambou/darktable-git-annex.git`
* in the category box enter `micharambou`
* click the `Install additional scripts` button

### Manually

* change to your lua scripts directory, `~/.config/darktable/lua/`
* enter the command `git clone https://github.com/micharambou/darktable-git-annex.git micharambou`
* enter the command `echo 'require "micharambou/git-annex"' >> luarc`


[git annex]: https://git-annex.branchable.com/
[darktable]: http://www.darktable.org/
