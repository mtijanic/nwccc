import std/[httpclient, options, streams, json, logging, db_sqlite, strutils, os, tables, parsecfg, sha1,
            asyncdispatch, asyncfutures, sequtils]
import neverwinter/[compressedbuf, nwsync, game]

import asynchttppool

type
  NwcccConfig* = tuple
    loglevel: logging.Level
    nwmaster: string
    nwnHome: string
    nwcccHome: string
    userAgent: string
    localDirs: seq[string]
    parallelDownloads: int

  NwcFile* = tuple
    name, author, license, version: string
    files: seq[tuple[filename, hash: string]]
    # TODO: 2da data, etc

const nwcccOptout = "[nwccc-optout]"

var db: DbConn
var http: AsyncHttpPool
var cfg: NwcccConfig
var credits: seq[string]
var localDirsCache = newTable[string, string]()

proc nwcccInit*(c: NwcccConfig) =
  cfg = c
  http = newAsyncHttpPool(cfg.parallelDownloads, cfg.userAgent)
  addHandler(newConsoleLogger(cfg.loglevel, "[$levelid] "))

  let home = if cfg.nwcccHome != "": cfg.nwcccHome else: findUserRoot() / "nwccc"
  createDir(home)

  let cache = home / "nwccc.sqlite3"
  let cacheExists = fileExists(cache)
  info "Using cache: " & cache & (if cacheExists: " (existing)" else: " (new)")
  db = open(cache, "", "", "")

  # To change the DB schema, simply add another row to the migrations seq.
  # - The first entry of the tuple is a human-readable description of the change.
  # - The second entry of the tuple is the sql code needed to bring the database
  #   to the state you want it to have. The code does not have to be idempotent
  #   (migrations only run once), but robustness can't hurt.

  type Migration = tuple[description: string, sql: seq[SqlQuery]]
  const migrations: seq[Migration] = @[
    # 0
    (
      "Initial database schema",
      @[
        sql """
          CREATE TABLE IF NOT EXISTS manifests(
            url      TEXT NOT NULL,
            mf_hash  TEXT NOT NULL
          );
        """,
        sql """
          CREATE TABLE IF NOT EXISTS resources(
            hash     TEXT NOT NULL,
            mf_id    INT  NOT NULL,
            UNIQUE(hash, mf_id)
          );
        """,
        sql """
          CREATE INDEX IF NOT EXISTS idx_hash ON resources(hash);
        """
      ]
    ),
    # 1
    (
      "Add table manifests_blacklist to blacklist successfully downloaded, but invalid manifests",
      @[sql """
        CREATE TABLE IF NOT EXISTS manifest_blacklist (
          mf_hash TEXT NOT NULL UNIQUE
        )
      """]
    )
  ]

  let migration = db.getValue(sql"PRAGMA user_version").parseInt
  # user_version holds the number of migrations applied, in order (migrations.len)
  # This means that the value you read here will be the next migration to apply:
  db.exec(sql"BEGIN")
  if migration > migrations.len:
    error "database file was created with newer version of utility, aborting for your own safety"
    quit(1)
  for mig in migrations[migration..<migrations.len]:
    notice "sqlite: Applying migration: ", mig.description
    for s in mig.sql:
      db.exec(s)
  db.exec(sql("PRAGMA user_version=" & $migrations.len))
  db.exec(sql"COMMIT")

  for dir in cfg.localDirs:
    for entry in walkDir(dir):
      if entry.kind == pcFile or entry.kind == pcLinkToFile:
        let hash = ($secureHashFile(entry.path)).toLowerAscii
        debug "Detected existing file with hash " & hash & " - " & entry.path
        localDirsCache[hash] = entry.path

proc nwcccIsManifestBlacklisted*(mfHash: string): bool =
  db.getValue(sql"select count(mf_hash) from manifest_blacklist where mf_hash = ?", mfHash) != "0"

proc nwcccBlacklistManifest*(mfHash: string) =
  error mfHash, ": blacklisting"
  db.exec(sql"insert into manifest_blacklist (mf_hash) values(?)", mfHash)

proc processManifest(baseUrl, mfHash: string): Future[bool] {.async.} =
  let fqurl = baseUrl & "/manifests/" & mfHash
  try:
    let mfRaw = await http.getContent(fqurl)
    if secureHash(mfRaw) != parseSecureHash(mfHash):
      raise newException(ValueError, "Checksum mismatch")
    let mf = readManifest(newStringStream(mfRaw))
    info "  Got " & $mf.entries.len & " entries, total size " & $totalSize(mf)
    db.exec(sql"BEGIN")
    let mfId = db.insertID(sql"INSERT INTO manifests(url, mf_hash) VALUES(?,?)", baseUrl, mfHash)
    for entry in mf.entries:
      discard db.tryExec(sql"INSERT INTO resources(hash, mf_id) VALUES(?,?)", entry.sha1, mfId)
    db.exec(sql"COMMIT")
    result = true

  except ManifestError:
    error fqurl & " failed to parse manifest: " & getCurrentExceptionMsg().split("\n", 2)[0]
    nwcccBlacklistManifest(mfHash)
    result = false

  except:
    error fqurl & " failed: " & getCurrentExceptionMsg().split("\n", 2)[0]
    result = false

proc nwcccUpdateCache*() {.async.} =
  let servers = parseJson(await http.getContent(cfg.nwmaster))

  # Build a list of advertised manifests that didn't opt out
  type ManifestEntry = tuple[url, mf: string]
  var manifests : seq[ManifestEntry]
  for srv in servers:
    if srv.contains("nwsync"):
      if srv["passworded"].getBool():
        debug "Skipping passworded server " & srv["session_name"].getStr() & "::" & srv["module_name"].getStr()
        continue
      if srv["module_description"].getStr().contains(nwcccOptout):
        notice "Skipping opt-out server " & srv["session_name"].getStr() & "::" & srv["module_name"].getStr()
        continue

      for mfNode in srv["nwsync"]["manifests"]:
        manifests.add((srv["nwsync"]["url"].getStr(), mfNode["hash"].getStr()))

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
    if nwcccIsManifestBlacklisted(mf.mf):
      info "[" & $idx & "/" & $manifests.len & "] Not downloading manifest " & mf.mf & ", blacklisted"
    elif db.getValue(sql"SELECT count(*) FROM manifests WHERE mf_hash=?", mf.mf).parseInt() > 0:
      info "[" & $idx & "/" & $manifests.len & "] Already have manifest " & mf.mf & " advertised by " & mf.url
    else:
      notice "[" & $idx & "/" & $manifests.len & "] Fetching " & mf.url & "/manifests/" & mf.mf
      futures.add processManifest(mf.url, mf.mf)

  if futures.len > 0:
    let results = await all futures
    if results.anyIt(not it):
      error "Some manifests failed to update correctly; read the logs above"

proc nwcccExtractFromNwsync*(hash: string): string =
  let nwsyncdir = findUserRoot() / "nwsync"
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
  for mfId in rows:
    let url = db.getValue(sql"SELECT url FROM manifests WHERE rowid=?", mfId)
    debug "Fetching from " & url & resource & " ..."
    try:
      let rawdata = await http.getContent(url & resource)
      let data = if rawdata[0..3] == magic: decompress(rawdata, makeMagic(magic))
             else: rawdata
      if secureHash(data) != parseSecureHash(hash):
        raise newException(ValueError, "Checksum mismatch on " & $hash)
      return data
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
