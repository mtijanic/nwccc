import std/[httpclient, options, streams, json, logging, db_sqlite, strutils, os, tables, parsecfg, sha1,
            asyncdispatch, asyncfutures, sequtils]
import neverwinter/[compressedbuf, nwsync]

import asynchttppool

type NwcccConfig* = tuple[
    loglevel: logging.Level,
    nwmaster: string,
    nwnHome: string,
    nwcccHome: string,
    userAgent: string,
    localDirs: seq[string],
    parallelDownloads: int,
]
type NwcFile* = tuple[
    name, author, license, version: string,
    files: seq[tuple[filename, hash: string]],
    # TODO: 2da data, etc
]
const nwcccOptout = "[nwccc-optout]"

var db: DbConn
var http: AsyncHttpPool
var cfg: NwcccConfig
var credits: seq[string]
var localDirsCache = newTable[string, string]()

proc getNwnHome(): string = 
    if cfg.nwnHome != "":
        return cfg.nwnHome
    elif defined(Linux):
        return getHomeDir() / ".local/share/Neverwinter Nights"
    elif defined(Windows) or defined(MacOSX):
        return getHomeDir() / "Documents/Neverwinter Nights"

proc nwcccInit*(c: NwcccConfig) = 
    cfg = c
    http = newAsyncHttpPool(cfg.parallelDownloads, cfg.userAgent)
    addHandler(newConsoleLogger(cfg.loglevel, "[$levelid] "))

    let home = if cfg.nwcccHome != "": cfg.nwcccHome else: getNwnHome() / "nwccc"
    createDir(home)

    let cache = home / "nwccc.sqlite3"
    let cacheExists = fileExists(cache)
    info "Using cache: " & cache & (if cacheExists: " (existing)" else: " (new)")
    db = open(cache, "", "", "")
    if not cacheExists:
        db.exec(sql"""
        CREATE TABLE IF NOT EXISTS manifests(
            url      TEXT NOT NULL,
            mf_hash  TEXT NOT NULL
        )""")
        db.exec(sql"""
        CREATE TABLE IF NOT EXISTS resources(
            hash     TEXT NOT NULL,
            mf_id    INT  NOT NULL,
            UNIQUE(hash, mf_id)
        )""");
        db.exec(sql"CREATE INDEX IF NOT EXISTS idx_hash ON resources(hash)")

    for dir in cfg.localDirs:
        for entry in walkDir(dir):
            if entry.kind == pcFile or entry.kind == pcLinkToFile:
                let hash = ($secureHashFile(entry.path)).toLowerAscii
                debug "Detected existing file with hash " & hash & " - " & entry.path
                localDirsCache[hash] = entry.path


proc processManifest(base_url, mf_hash: string): Future[bool] {.async.} =
    try:
        let mfRaw = await http.getContent(base_url & "/manifests/" & mf_hash)
        let mf = readManifest(newStringStream(mf_raw))
        info "  Got " & $mf.entries.len & " entries, total size " & $totalSize(mf)
        db.exec(sql"BEGIN")
        let mf_id = db.insertID(sql"INSERT INTO manifests(url, mf_hash) VALUES(?,?)", base_url, mf_hash)
        for entry in mf.entries:
            discard db.tryExec(sql"INSERT INTO resources(hash, mf_id) VALUES(?,?)", entry.sha1, mf_id)
        db.exec(sql"COMMIT")
        result = true
    except:
        error "Failed: " & getCurrentExceptionMsg().split("\n", 2)[0]
        result = false

proc nwcccUpdateCache*() {.async.} =
    let servers = parseJson(await http.getContent(cfg.nwmaster))

    # Build a list of advertised manifests that didn't opt out
    type ManifestEntry = tuple[url, mf : string]
    var manifests : seq[ManifestEntry]
    for srv in servers:
        if srv.contains("nwsync"):
            if srv["passworded"].getBool():
                debug "Skipping passworded server " & srv["session_name"].getStr() & "::" & srv["module_name"].getStr()
                continue
            if srv["module_description"].getStr().contains(nwcccOptout):
                notice "Skipping opt-out server " & srv["session_name"].getStr() & "::" & srv["module_name"].getStr()
                continue

            for mf_node in srv["nwsync"]["manifests"]:
                manifests.add((srv["nwsync"]["url"].getStr(), mf_node["hash"].getStr()))

    # If an entry is in cache but is not advertised, it's stale and we remove from cache
    let rows = db.getAllRows(sql"SELECT rowid, url, mf_hash FROM manifests")
    for row in rows:
        var have = false
        for (url, mf) in manifests:
            if url == row[1] and mf == row[2]:
                have = true
                break
        if not have:
            notice "Removing stale manifest " & row[2] & " previously advertised by " & row[1]
            db.exec(sql"BEGIN")
            db.exec(sql"DELETE FROM manifests WHERE rowid=?", row[0])
            db.exec(sql"DELETE FROM resources WHERE mf_id=?", row[0])
            db.exec(sql"COMMIT")

    var futures: seq[Future[bool]]
    for idx, mf in manifests:
      if db.getValue(sql"SELECT count(*) FROM manifests WHERE mf_hash=?", mf.mf).parseInt() > 0:
          notice "[" & $(idx) & "/" & $(manifests.len) & "] Already have manifest " & mf.mf & " advertised by " & mf.url
      else:
          futures.add processManifest(mf.url, mf.mf)

    if futures.len > 0:
      let results = await all futures
      if results.anyIt(not it):
        error "Some manifests failed to update correctly; read the logs above"

proc nwcccExtractFromNwsync*(hash: string): string =
    let nwsyncdir = getNwnHome() / "nwsync"
    for file in walkDir(nwsyncdir):
        if file.path.contains("nwsyncdata_") and file.path.endsWith(".sqlite3"):
            debug "Checking local nwsync database " & file.path
            let shard = open(file.path, "", "", "")
            let data = shard.getValue(sql"SELECT data FROM resrefs WHERE sha1=?", hash)
            if data != "":
                return data
    return ""


proc nwcccDownloadFromSwarm*(hash: string): Future[string] {.async.} =
    let resource = "/data/sha1" / hash[0..1] / hash[2..3] / hash
    const magic = "NSYC"

    let rows = db.getAllRows(sql"SELECT mf_id FROM resources WHERE hash=? ORDER BY RANDOM()", hash)
    for mf_id in rows:
        let url = db.getValue(sql"SELECT url FROM manifests WHERE rowid=?", mf_id)
        debug "Fetching from " & url & resource & " ..."
        try:
            let rawdata = await http.getContent(url & resource)
            if rawdata[0..3] == magic:
                return decompress(rawdata, makeMagic(magic))
            return rawdata
        except:
            info "Fetching from " & url & resource & " failed: " & getCurrentExceptionMsg()

    raise newException(OSError, "Unable to download hash " & hash & " from any server in swarm")


proc nwcccWriteFile*(filename, content, destination: string) =
    if fileExists(destination):
        # write to hak (TODO)
        raise newException(OSError, "Writing to HAK is not implemented")
    else:
        # write to directory
        info "Writing " & destination / filename
        createDir(destination)
        writeFile(destination / filename, content)

proc nwcccParseNwcFile*(filename: string): NwcFile =
    let dict = loadConfig(filename)
    result.name = dict.getSectionValue("", "Name")
    result.author = dict.getSectionValue("", "Author")
    result.license = dict.getSectionValue("", "License")
    result.version = dict.getSectionValue("", "Version")
    if dict.hasKey("files"):
        for key in dict["files"].keys:
            result.files.add((key, dict.getSectionValue("files", key)))

proc nwcccProcessNwcFile*(nwcfile, destination: string) {.async.} =
    try:
        notice "Processing " & nwcfile
        let nwc = nwcccParseNwcFile(nwcfile)
        let summary = nwc.name & " v" & nwc.version & " by " & nwc.author & " (" & nwc.license & ")"
        info summary
        credits.add(summary)
        for (filename, hash) in nwc.files:
            if localDirsCache.hasKey(hash):
                if localDirsCache[hash] != (destination / filename):
                    info "Already have hash " & hash & " as " & localDirsCache[hash] & "; copying"
                    copyFile(localDirsCache[hash], filename)
                else:
                    info "Already have same file content for " & filename
            else:
                var data = nwcccExtractFromNwsync(hash)
                if data != "":
                    info "Found hash " & hash & " in local nwsync data"
                else:
                    notice "Downloading " & filename & " (" & hash & ")"
                    data = await nwcccDownloadFromSwarm(hash)
                nwcccWriteFile(filename, data, destination)
                localDirsCache[hash] = destination / filename
    except:
        error "Processing " & nwcfile & " failed: " & getCurrentExceptionMsg().split("\n", 2)[0]

proc nwcccWriteCredits*(file: string) =
    let f = openFileStream(file, fmAppend)
    for line in credits:
        f.write(line & "\n")
    notice "Wrote credits to " & file
