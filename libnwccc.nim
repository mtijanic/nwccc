import std/[httpclient, options, streams, json, logging, db_sqlite, strutils, os, tables, parsecfg, sha1]
import neverwinter/[compressedbuf, nwsync]

type NwcccConfig* = tuple[
    loglevel: logging.Level,
    nwmaster: string,
    nwnHome: string,
    nwcccHome: string,
    userAgent: string,
    localDirs: seq[string],
]
type NwcFile* = tuple[
    name, author, license, version: string,
    files: seq[tuple[filename, hash: string]],
    # TODO: 2da data, etc
]
const nwcccOptout = "[nwccc-optout]"

var db: DbConn
var http: HttpClient
var cfg: NwcccConfig

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
    http = newHttpClient(cfg.userAgent)
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


# TODO: Switch to async and download all manifests in parallel
proc processManifest(base_url, mf_hash: string) =
    try:
        let mf_raw = http.getContent(base_url / "manifests" / mf_hash)
        let mf = readManifest(newStringStream(mf_raw))
        info "  Got " & $mf.entries.len & " entries, total size " & $totalSize(mf)
        db.exec(sql"BEGIN")
        let mf_id = db.insertID(sql"INSERT INTO manifests(url, mf_hash) VALUES(?,?)", base_url, mf_hash)
        for entry in mf.entries:
            discard db.tryExec(sql"INSERT INTO resources(hash, mf_id) VALUES(?,?)", entry.sha1, mf_id)
        db.exec(sql"COMMIT")
    except:
        error "Failed: " & getCurrentExceptionMsg()

proc nwcccUpdateCache*() =
    let servers = parseJson(http.getContent(cfg.nwmaster))

    # Build a list of advertised manifests that didn't opt out
    var manifests : seq[tuple[url, mf : string]]
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

    var i = 0
    for (url, mf) in manifests:
        i+=1
        if db.getValue(sql"SELECT count(*) FROM manifests WHERE mf_hash=?", mf).parseInt() > 0: 
            notice "[" & $i & "/" & $manifests.len & "] Already have manifest " & mf & " advertised by " & url
        else:
            notice "[" & $i & "/" & $manifests.len & "] Fetching " & url & "/manifests/" & mf
            processManifest(url, mf)


proc nwcccDownloadFromSwarm*(hash: string): string =
    let resource = "/data/sha1" / hash[0..1] / hash[2..3] / hash
    const magic = "NSYC"

    let rows = db.getAllRows(sql"SELECT mf_id FROM resources WHERE hash=? ORDER BY RANDOM()", hash)
    for mf_id in rows:
        let url = db.getValue(sql"SELECT url FROM manifests WHERE rowid=?", mf_id)
        debug "Fetching from " & url & resource & " ..."
        try:
            let rawdata = http.getContent(url & resource)
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

proc nwcccProcessNwcFile*(nwcfile, destination: string) =
    try:
        notice "Processing " & nwcfile
        let nwc = nwcccParseNwcFile(nwcfile)
        info nwc.name & " v" & nwc.version & " by " & nwc.author & " (" & nwc.license & ")"
        for (filename, hash) in nwc.files:
            if localDirsCache.hasKey(hash):
                if localDirsCache[hash] != (destination / filename):
                    info "Already have hash " & hash & " as " & localDirsCache[hash] & "; copying"
                    copyFile(localDirsCache[hash], filename)
                else:
                    info "Already have same file content for " & filename
            else:
                notice "Downloading " & filename & " (" & hash & ")"
                let data = nwcccDownloadFromSwarm(hash)
                nwcccWriteFile(filename, data, destination)
                localDirsCache[hash] = destination / filename
    except:
        error "Processing " & nwcfile & " failed: " & getCurrentExceptionMsg()