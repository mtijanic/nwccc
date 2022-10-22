import std/[httpclient, options, streams, json, logging, db_sqlite, strutils, os, tables, parsecfg]
import neverwinter/[compressedbuf, nwsync]

type NwcccConfig* = tuple[
    loglevel: logging.Level,
    nwmaster: string,
    nwnHome: string,
    nwcccHome: string,
    userAgent: string,
    destination: string,
]
type NwcFile* = tuple[
    name, author, license, version: string,
    files: seq[tuple[filename, hash: string]],
    # TODO: 2da data, etc
]

var db: DbConn
var http: HttpClient
var cfg: NwcccConfig

var downloaded = newTable[string, string]()

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

    # TODO: Prepopulate downloaded table with hashes of existing files

proc nwcccUpdateCache*() =
    let servers = parseJson(http.getContent(cfg.nwmaster))

    for srv in servers:
        if srv.contains("nwsync"):
            let base_url = srv["nwsync"]["url"].getStr()
            let manifests = srv["nwsync"]["manifests"]
            for mf_node in manifests:
                let mf_hash = mf_node["hash"].getStr()
                debug "trying " & mf_hash
                if db.getValue(sql"SELECT count(*) FROM manifests WHERE mf_hash=?", mf_hash).parseInt() > 0: 
                    info "Skipping manifest " & mf_hash
                    continue
            
                let mf_url = base_url & "/manifests/" & mf_hash
                notice "Fetching " & mf_url
                try:
                    # TODO: Switch to async and download all manifests in parallel
                    let mf_raw = http.getContent(mf_url)
                    let mf = readManifest(newStringStream(mf_raw))
                    info "  Got " & $mf.entries.len & " entries, total size " & $totalSize(mf)
                    db.exec(sql"BEGIN")
                    let mf_id = db.insertID(sql"INSERT INTO manifests(url, mf_hash) VALUES(?,?)", base_url, mf_hash)
                    for entry in mf.entries:
                        discard db.tryExec(sql"INSERT INTO resources(hash, mf_id) VALUES(?,?)", entry.sha1, mf_id)
                    db.exec(sql"COMMIT")
                except:
                    error "Failed: " & getCurrentExceptionMsg()

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

proc nwcccProcessNwcFile*(nwcfile: string) =
    try:
        notice "Processing " & nwcfile
        let nwc = nwcccParseNwcFile(nwcfile)
        info nwc.name & " v" & nwc.version & " by " & nwc.author & " (" & nwc.license & ")"
        for (filename, hash) in nwc.files:
            if downloaded.hasKey(hash):
                if downloaded[hash] != filename:
                    info "Already have hash " & hash & " as " & downloaded[hash] & "; copying"
                    copyFile(downloaded[hash], filename)
                else:
                    info "Already have same file content for " & filename
            else:
                notice "Downloading " & filename & " (" & hash & ")"
                let data = nwcccDownloadFromSwarm(hash)
                nwcccWriteFile(filename, data, cfg.destination)
                downloaded[hash] = filename
    except:
        error "Processing " & nwcfile & " failed: " & getCurrentExceptionMsg()