version       = "0.1.1"
author        = "mtijanic"
description   = "Neverwinter Custom Content Compiler"
license       = "MIT"
binDir        = "bin/"
bin           = @["nwn_ccc"]
installDirs   = @["nwccc"]

requires "nim >= 1.6.0"
requires "neverwinter >= 1.5.7"
requires "docopt >= 0.6.8"
requires "zip >= 0.3.1"
