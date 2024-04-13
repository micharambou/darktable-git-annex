git annex darktable integration
===============================
![darktable git annex overview](/images/Screenshot_20240413_124335.png)
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
* in the category box enter `dt-git-annex`
* click the `Install additional scripts` button

### Manually

* change to your lua scripts directory, `~/.config/darktable/lua/`
* enter the command `git clone https://github.com/micharambou/darktable-git-annex.git dt-git-annex`

Features
--------

#### git annex actions

* execute git annex add/get/drop for selected images or the whole collection. You may also include sidecar files.

> [!NOTE]
> It is adviseable to check xmp files into git rather than git-annex. Git annex will do this automatically if you configure annex.largefiles accordingly:
```git annex config --set annex.largefiles 'not (include=*.xmp)'```

![darktable git annex actions](/images/Screenshot_20240413_130024.png)

#### git annex sync 

* git annex sync multiple user-defined repositories at button press. Check checkbox --content to also transfer annexed file contents.
* a default repository can be configured in preferences -> Lua options -> `Git annex: default sync repository`
* a database scan can be initiated by hitting the button "scan db": this scans the darktable database for repositories and adds them to the list

![darktable git annex sync](/images/Screenshot_20240413_130143.png)

#### Pre/Post Import hook: automaticall add images to annex on import

* enable this feature in preferences -> Lua options -> Git annex: enable `Pre/Post Import Hook add` to automatically add files to annex on import. 

> [!NOTE]
> This only works, if you choose “add to library” from import module but not by “copy & import" (yet)

#### Metadata

* add custom user-defined rules/image property conditions to match selected images or a collection against and either apply particular metadata with git annex or git annex copy/move to a user-defined remote
* examples:

| condition | metadata field / action | value |
| --------- | ------------------------| ----- |
| Rating >= 3 Stars | annex.numcopies  | 3 |
| Rating = -1 Star (reject) | move | trash-repo |
| Tag attached: Venice | tag | Venice |

![darktable git annex metadata overview](/images/Screenshot_20240413_130245.png)

![darktable git annex metadata settings](/images/Screenshot_20240413_130417.png)

#### Sidecar History `(experimental)`

* enable this feature in preferences -> Lua options -> `Git annex: enable sidecar history feature (experimental)` and restart darktable
* go back and forth between previous versions of git-tracked sidecar files of an image by selecting one particular commit from the list
* selected commit will be automatically checked out (git checkout %commit% /path/to/file)
* re-apply checked out sidecar file by clicking `load sidecar file...` in history stack module (overwrite mode recommended)

![darktable git annex sidecar history overview](/images/Screenshot_20240413_130632.png)

FAQ
---
### OS support?
This is currently tested and developed for linux environments only. Multi OS support may come in the future.

### Are git & git annex additional software requirements?
Yes. Install [git][] & [git annex][] through the paketmanager of your choice. Make sure, the git binary is within your path.

### Metadata: how can I add additional image properties and/or metadata fields/actions?
At the moment, this is not configurable. The adjustment requires code changes. Feel free to contribute or raise an issue or leave a comment on [discuss.pixls.us][].

### Sidecar History: Why do I have to reaply the sidecar manually?
This is due to a limitation of darktable's Lua API. See [#16599]

[git]: https://git-scm.com/
[git annex]: https://git-annex.branchable.com/
[darktable]: http://www.darktable.org/
[discuss.pixls.us]: https://discuss.pixls.us/t/reviving-darktable-git-annex-integration-lua/
[#16599]: https://github.com/darktable-org/darktable/issues/16599