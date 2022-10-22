version       = "0.1.0"
author        = "mtijanic"
description   = "Neverwinter Custom Content Compiler"
license       = "MIT"
bin           = @["nwn_ccc"]
installDirs   = @["nwccc"]

requires "nim >= 1.6.0"
requires "neverwinter >= 1.5.6"
requires "docopt >= 0.6.8"
requires "zip >= 0.3.1"