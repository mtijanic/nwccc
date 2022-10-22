# Neverwinter Custom Content Compiler

NWCCC is a mechanism for decentralized custom content distribution and compilation.

## Problem statement

The traditional NWVault approach of hosting NWN custom content (CC) is for CC authors to upload packages containing their work on a "project page", and module builders would then download these and merge them into the module-specific HAKs or NWSync manifests. Merging multiple packages can be a painful process, so the community standardized around two solutions:

1. Content compilations such as CEP or ProjectQ collect a wide range of CC packages and merge them into a single giant package that "everyone can use".
2. Individual CC artists coordinate to "reserve" 2DA lines and TLK entries, to make the merging process easier.

Furthermore, the process of improving on another author's work is not well defined, so typically an artist will take a package, make modifications, and then publish a new version as a new project. Then this new version might be included into CEP. Overall, it makes tracking down version history, ownership and license status of a piece of CC very hard.

Lastly, several projects have disappeared from NWVault for a variety of reasons. Even projects published under a permissive license can be pulled by the author, leaving modules that depended on them unplayable.

NWCCC solves these issues by offering a standardized and decentralized way to host and merge NWN Custom Content.

## Proposal overview

The basic idea is to separate hosting of CC assets (i.e. models, textures, etc) from metadata that describes how the assets are used. Both the assets and metadata can be hosted and managed separately, and NWCCC describes a protocol for pairing them and importing into modules.

The assets in question is already stored, in many duplicates, on the NWSync servers of various PWs. The files are content-addressable - i.e. if you know the hash of the file, you can download it from the server. Additionally, each NWSync server contains a Manifest listing all the files it serves under which names (a list of `{filename, hash}` pairs).

Building on top of the NWSync infrastructure, we introduce a new type of metadata file that describes everything needed to add a single bit of CC (e.g. a custom placeable) to a module. This `.nwc` file is a text file listing:

- The authors of the relevant bit of CC
- License under which the CC is available
- List of files (`{filename, hash}` pairs) constituting this bit of CC
- Required 2DA and TLK entries needed to use the CC

Given such a file, one can unambiguously download all the necessary data from NWSync servers and build a usable HAK file containing the new CC.

CC artists would then host repositories of `*.nwc` files describing their work, organized how they see fit. Curated compilations would exist as common repositories containing collections from multiple artists. These repositories do not host the data itself, only the metadata text files.

Module builders would browse one or more of these repositories, select the files they want and feed them into a "self-checkout" tool (`nwn_ccc.exe`), which would download the necessary CC files and merge them into HAKs (merging with existing module CC if needed).

### Metadata files
The `*.nwc` files are simple TOML/INI files with a custom extension, using a fixed format. An example of one such file for a placeable would look like:

```toml
Name = "Fancy Rock"
Authors = "This Guy and That Other Guy"
License = "CC BY-NC-SA 3.0"
Version = "1.0.0" # For human reference only

#
# Screenshots can be shown by GUI programs when browing the repo
#
[screenshots]
thumbnail = "https://i.ytimg.com/vi/eBYPMsMXmnk/maxresdefault.jpg"

#
# List all required files in the format:
#    name-of-file = <hash of file>
#
[files]
guy_fancyrock.mdl = "3f786850e387550fdab836ed7e6dc881de23001b"
guy_fancyrock.mtr = "7547ccb985abc52d9cbe89700b6d46587f1b0108"
guy_rock_d.dds = "89e6c98d92887913cadf06b2adb97f26cde4849b"
guy_rock_n.tga = "2b66fd261ee5c6cfc8de7fa466bab600bcfe4f69"

#
# You can optionally add a line to the module's custom TLK
# This gives you a symbolic name for the strref you can use in the 2DA
#
[tlk]
plcname = "Fancy Rock"

#
# Suggested values for a placeables.2da entry for this placeable
# Any omitted columns will be set to ****
#
[placeables.2da]
Label = "Guy: Fancy Rock" # Optional, uses top level Name otherwise
StrRef = "$plcname" # Replace with the TLK entry shown above
ModelName = "guy_fancyrock"
SoundAppType = 17
ShadowSize = 1
BodyBag = 0
Static = 1
```
#### Metadata repositories
A metadata repository is really any directory containing one or more `nwc` files. These can be organized into subfolders however the maintainer likes.  Some options would be:

- By category, e.g. `repo/placeables/nature/guy_fancyrock.nwc`
- By author, e.g. `repo/this-guy/guy_fancyrock.nwc`

Ideally the repositories would be version controlled through e.g. `git` so it's easier to follow changes to the metadata and revert to previous versions. 

NWVault would host one such repository that CC artists can use instead of managing their own.

### Self-checkout tool
The `*.nwc` metadata files are consumed by the self-checkout tool, `nwn_ccc.exe`. In its most naive form, this tool would:
1. Query NWMaster to get a list of nwsync servers
2. Query each nwsync server to get a list of files they have
3. For each file in `[files]` section above, download the files from nwsync servers that have it
4. Spit out a `placeables.2da` line for the new rock 
5. Spit out a `credits.txt` entry with author/license info

In reality, the data from (1) and (2) would be cached and not queried regularly. The tool would also check local HAKs and nwsync to see if the file is available locally before downloading it from the internet. Lastly, a NWVault-hosted NWSync repo is queried first, and fallback to PW repos is done only if data is not available on NWVault

The tool can also work in _append_ mode, where it would be told about the existing module CC and it would append the 2DA and TLK entries to the existing files. This way, adding more CC to your project is one click away.

#### Self-checkout GUI
The `nwn_ccc.exe` is a command line (CLI) tool. It is configured through a combination of config files, environment variables and CLI switches.

Because the tool works with metadata files, which are organized into a directory structure, it integrates nicely with existing workflows using any file browser.

This means that `nwn_ccc.exe` can be registered as a handler for `*.nwc` files and a module builder would just need to double-click on the `.nwc` file to integrate it into the module. 

Alternatively, the tool can register "right click context menus" which would expose options such as "Import whole directory" when right clicking on a folder in a file browser.

Of course, the CLI tool can also be wrapped in proper GUI programs, whether standalone or as plugins to bigger toolsets. Or as web browser plugins.

### Scope
The NWCCC project has a limited and well defined scope - its purpose is to streamline hosting and importing of _art_ assets into NWN modules. Specifically, NWCCC supports:
- Tilesets
- Placeable models
- Creature models
- Door models
- VFX
- Skyboxes
- Portraits
- Music and SFX
- Soundsets
- Icons
- Body and Armor Parts (auto-merge as a stretch goal)

Conversely, the following are out of scope for NWCCC:
- Ruleset changes (e.g. `classes.2da`, `racialtypes.2da` mods)
- New spells or feats
- Scripted systems
- Resource blueprints (i.e. `.ut*` files)

NWCCC can be used to download such files, but no automatic merging would be performed.

### Resolving conflicts

NWCCC can detect two types of conflicts with CC - duplicate filenames, and duplicate 2DA entries. In both cases it will report a warning and let the user choose whether to keep the existing entry or replace with the new one.

### Append mode
To run in `append` mode, NWCCC needs to be given path to the 2DA files to append to. Any imported asset that comes with the appropriate `[*.2da]` section in the `nwc` file will get the resulting entry added to the corresponding 2DA.

Entries are added to the first 2DA line with the `LABEL` column equaling `****`. This allows you to reserve lines that NWCCC will not touch by giving them a reserved label.

### Configuring NWCCC
There are three ways to configure NWCCC behavior: CLI arguments, environment variables and config file. They are checked in order, using the first value found.

By default, `nwn_ccc.exe` will simply download files to `CWD`. Running e.g. 
```
nwn_ccc.exe repo/placeables/nature/guy_fancyrock.nwc
```
will just download the four files (`mdl, mtr, dds, tga`) into the current working directory. However a more complex invocation of
```
nwn_ccc.exe --recursive=repo/placeables/nature \
 --append=mymod/top.hak \
 --tlk=mymod/mymod.tlk \
 --destination=mymod/placeables.hak \
 --nwc=mymod/nwc.hak \
 --credits=mymod/credits.txt
```
will download all nature placeables from the given repo, package the asset files into `placeables.hak`, and update  `mymod.tlk` and `placeables.2da` in `top.hak`. It will also save a copy of all the `nwc` files in `nwc.hak` for future use, and populate the `credits.txt` file

The arguments can also be specified in `$NWN_HOME/nwccc/nwccc.cfg` and then omitted from CLI.

## Usecase overview

### UC-1: CC artist wants to publish a new placeable
1. Artist creates a new placeable - model, textures, 2DA entry
2. Artist uploads assets (mdl, mtr, textures) to the Vault NWSync repo
    - Or any server specific nwsync repo
3. Artist creates `plc.nwc` file describing this placeable
4. Artist uploads `plc.nwc` file to the Vault metadata repo
    - Or any other metadata repo, e.g. hosted on github
5. Artist announces new work on vault, discord, etc.

### UC-2: CC artist wants to update an already published placeable
1. Artist modifies the art assets as desired
2. Artist uploads new assets (mdl, mtr, textures) to the Vault NWSync repo
    - Or any server specific nwsync repo
3. Artist updates `plc.nwc` file describing this placeable with new hashes
4. Artist pushes updated `plc.nwc` file to the Vault metadata repo
    - Or any other metadata repo, e.g. hosted on github
5. Artist announces update on vault, discord, etc.

### UC-3: Module builder compiling initial placeable hak for module
1. Builder browses one or more metadata repos for placeables they want
2. Builder selects the `nwc` files for all the placeables they want
    - Option: Copy desired `nwc` files into a different directory
    - Option: Maintain a list of desired `nwc` files
    - Option: Just do (3) directly for every file
3. Builder runs `nwn_ccc.exe` on the desired `nwc` files, in append mode
4. Builder associates the new hak with their module

### UC-4: Module builder adding new content into existing placeable hak
1. Builder browses one or more metadata repos for placeables they want
2. Builder selects the `nwc` files for all the placeables they want
    - Option: Copy desired `nwc` files into a different directory
    - Option: Maintain a list of desired `nwc` files
    - Option: Just do (3) directly for every file
3. Builder runs `nwn_ccc.exe` on the desired `nwc` files, in append mode
    - Builder specifies existing haks for append and destination 

### UC-5: Module builder wants to update all CC files to latest version
1. Builder fetches latest version of metadata repos they used
2. Builder selects the `nwc` files they already imported
3. Builder runs `nwn_ccc.exe --resolve=keep-newer` on the desired `nwc` files, in append mode
    - Builder specifies existing haks for append and destination 

### UC-6: Modder wants to make a curated collection of CC (e.g. CEP)
1. Modder browses one or more metadata repos for files they want
2. Modder copies the `nwc` files into their own metadata repo
3. Modder publishes the new metadata repo, ideally version controlled (e.g. `github` repo)
4. Modder announces the new curated repo on nwvault, discord, etc


# FAQ

#### Q: Are you trying to replace NWVault?
A: Not at all! The vault is still the primary host of CC, we're just changing the way in which it serves content. The vault already sort of supports this as part of the "Curated Content" initiative for SP modules (more details: https://sync.neverwintervault.org/).

#### Q: Why are body parts not supported initially?
A: Body part models require internal node names to be the same as the model name, and model name needs to follow a strict naming convention. You cannot just rename the model file, you also need to modify the internal node names, which means changing the model content and thus its hash.

You can use NWCCC to download these models, but the merging needs to be performed manually.

#### Q: Can a PW opt out of being used for storage through NWSync
A: There will be a mechanism for them to _ask_ for this, but there is no way to force clients to honor it. If your content is available for players to download in order to play your PW, it is also by definition available for module builders to download and use in their own modules.

#### Q: What happens if an author deletes the CC they posted via NWCCC?
A: Depends, probably nothing. When posting new content, the author posts the `.nwc` files to the metadata repo, and the art assets to the NWVault NWSync repo. Modules that use the art will clone the metadata repo and import the art assets into their own NWSync server.
The author can then delete the original `.nwc` files and the asset files from the vault, but anyone who gets a copy of the `.nwc` file in whatever way can download it from any NWSync server that serves the data. Data is only lost if removed from NWVault _and_ no one is using it on their PW.

#### Q: Isn't this auto-downloading thing a security vulnerability?
A: No more than nwsync itself is. It is certainly possible to deliver a `virus.exe` file to someone downloading assets via NWCCC, but it will be saved as a non-executable file of different type. The would-be victim would have to go out of their way to run it.
Worst case, someone could deliver an offensive image as e.g. portrait texture, but same can be done by a PW today via nwsync.
