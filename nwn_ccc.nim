import docopt;
let ARGS = docopt """
NWCCC - Neverwinter Custom Content Compiler

Usage:
  nwn_ccc [options] <nwcfile>...
  nwn_ccc [options] -f <nwcfile-list>
  nwn_ccc [options] -r <directory>
  nwn_ccc [options] -u | --update-cache
  nwn_ccc [options] -g <nwc> <spec>... [-s <search>...]
  nwn_ccc -h | --help

Options:
  -a, --append=<tophak>        Run in append mode, modifying 2DAs in <tophak>; can either be a hak file or a directory
  -d, --destination=<dest>     Download all asset files to <dest>; can either be a hak file or a directory [default: ./]
  -t, --tlk=<tlkfile>          Add TLK entries to <tlkfile> when running in append mode
  -r, --recursive=<dir>        Recursively process all NWC files in <dir>
  -n, --nwc=<nwchak>           Store a copy of processed NWC files in <nwchak>; can either be a hak file or a directory
  -c, --credits=<file>         Write credit fragments to <file> [default: credits.txt]
  -f, --filelist=<filelist>    Process all NWC files in <filelist>
  -g, --generate               Generate <nwc> from <spec>, optionally also using <search> to look up dependencies
  -s, --search=<search>...     Add <search> to search path (for --generate only)
  -u, --update-cache           Update local manifest cache
  -l, --local-cache=<dir>      Also search <dir> for local files before downloading
  --parallel=<N>               Parallel downloads [default: 5]

  -v, --verbose                Verbose prints as files are being processed
  -q, --quiet                  Suppresses all non-error prints
  -h, --help                   Print this help message and exit

  --noenv                      Ignore environment variables for config options (except NWN_HOME)
  --nwccc-home=<homedir>       Override NWCCC home directory (default $NWCCC_HOME, then $NWN_HOME/nwccc)
  --userdirectory=<userdir>    Override NWN user directory (default $NWN_HOME, then autodetect)

  --resolve=<policy>           Conflict resolve policy [default: fail]
                               Valid policies:
                                   ask: Prompt user for answer every time
                                   new: Overwrite older files with newer
                                   old: Keep older files, discard newer
                                   big: Overwrite smaller files with larger
                                   small: Overwrite larger files with smaller
                                   fail: Report error and abort
"""
import std/[os, logging, strutils, sequtils, streams, asyncdispatch, parsecfg]
import libnwccc

var cfg: NwcccConfig
cfg.parallelDownloads = ($ARGS["--parallel"]).parseInt
cfg.loglevel = if ARGS["--verbose"]: lvlDebug elif ARGS["--quiet"]: lvlError else: lvlNotice
cfg.nwmaster = "http://api.nwn.beamdog.net/v1/servers"
cfg.userAgent = "nwccc"

# Register directories which will be scanned for files to copy locally
cfg.localDirs.add($ARGS["--destination"])
if ARGS["--local-cache"]:
  cfg.localDirs.add($ARGS["--local-cache"])

if ARGS["--userdirectory"]:
  cfg.nwnHome = $ARGS["--userdirectory"];

if ARGS["--nwccc-home"]:
  cfg.nwcccHome = $ARGS["--nwccc-home"];
elif existsEnv("NWCCC_HOME") and not ARGS["--noenv"]:
  cfg.nwcccHome = getEnv("NWCCC_HOME")

nwcccInit(cfg)
if ARGS["--update-cache"]:
  waitFor nwcccUpdateCache()

# TODOs
if ARGS["--append"]: warn "append mode not yet implemented"
if ARGS["--tlk"]: warn "writing to TLK not yet implemented"
if ARGS["--resolve"]: warn "auto resolve not yet implemented"

proc processNwc(nwcfile: string) =
  waitFor nwcccProcessNwcFile(nwcfile, $ARGS["--destination"])
  if ARGS["--nwc"]:
    nwcccWriteFile(nwcfile.extractFilename(), readFile(nwcfile), $ARGS["--nwc"])

if ARGS["--filelist"]:
  for nwcfile in lines($ARGS["--filelist"]):
    processNwc(nwcfile)
elif ARGS["--recursive"]:
  for nwcfile in walkDirRec($ARGS["--recursive"]):
    if nwcfile.toLowerAscii.endsWith(".nwc"):
      processNwc(nwcfile)
else:
  for nwcfile in ARGS["<nwcfile>"]:
    processNwc(nwcfile)

if ARGS["--credits"]:
  nwcccWriteCredits($ARGS["--credits"])

if ARGS["--generate"]:
  let nwc = $ARGS["<nwc>"]

  if fileExists(nwc) or dirExists(nwc) or symlinkExists(nwc):
    raise newException(ValueError, "will not clobber: " & $nwc)

  let dict = nwcccGenerate(toSeq ARGS["<spec>"], toSeq ARGS["--search"])
  dict.writeConfig newFileStream(nwc, fmWrite)
  notice "nwc: ", nwc, " written"
