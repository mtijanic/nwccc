import std/[asyncdispatch, httpclient, logging, strutils, times]
from std/net import TimeoutError

type
  QueueEntry = ref object
    url: string
    future: Future[string]
    progress: ProgressChangedProc[Future[void]]
    transferStart: Time
      ## Timestamp when the transfer was started (moved to inflight).
    initialDataTimeout: Natural
      ## msec: timeout if no data is received at all
    xferTimeout: Natural
      ## msec: timeout even if data is being received
    firstData: bool
      ## Received data?
    lastProgressReport: Time
      ## Last timestamp we reported progress to the user: Either data transfer
      ## or "no data yet" messages.

  AsyncHttpPoolObj = object
    parallelism: Positive
    clientAvailable: AsyncEvent
    clients: seq[AsyncHttpClient]
    queue: seq[QueueEntry]
    inflight: seq[QueueEntry]

  AsyncHttpPool* = ref AsyncHttpPoolObj

proc `=destroy`*(pool: var AsyncHttpPoolObj) =
  unregister(pool.clientAvailable)

func `$`*(pool: AsyncHttpPool): string =
  format("HttpPool[$1/$2 available, $3 queued, $4 inflight]",
    pool.clients.len, pool.parallelism,
    pool.queue.len,
    pool.inflight.len)

proc downloadAndResolve(pool: AsyncHttpPool, ahttp: AsyncHttpClient, qe: QueueEntry) {.async.} =
  defer:
    ahttp.onProgressChanged = nil
    pool.clients.add(aHttp)
    pool.clientAvailable.trigger()
    pool.inflight.del(pool.inflight.find(qe))

  pool.inflight.add(qe)
  qe.transferStart = getTime()
  qe.lastProgressReport = getTime()

  ahttp.onProgressChanged = proc (total, progress, speed: BiggestInt) {.async.} =
    qe.firstData = true
    qe.lastProgressReport = getTime()
    if not isNil qe.progress:
      result = qe.progress(total, progress, speed)
    else:
      info qe.url, ": ", progress, " of ", total, ", current rate: ", speed div 1000, "kb/s"

  # We start one async timer per inflight xfer to check if we're timing out - simple UX
  addTimer(1000, false) do (fd: AsyncFD) -> bool:
    if qe.future.finished: return true # done or error
    let now = getTime()

    # No point calling again if we have data. All logic below only deals with pre-transfer stage.
    if qe.firstData: return true

    # If we exceed the initial transfer timeout, fail the future
    if qe.initialDataTimeout > 0 and
       now - qe.transferStart > initDuration(milliseconds = qe.initialDataTimeout):
      qe.future.fail(newException(TimeoutError, "timed out waiting for initial data"))
      return true

    # Otherwise, report inactivity every
    if now - qe.lastProgressReport > initDuration(seconds = 6):
      qe.lastProgressReport = now
      info pool, " ", qe.url, ": Waiting for data .. (for ", (now - qe.transferStart).inSeconds, " s)"
    false

  info pool, " starting download: ", qe.url
  let fut = ahttp.getContent(qe.url)
  if qe.xferTimeout > 0:
    let timeoutFut = withTimeout(fut, qe.xferTimeout)
    yield timeoutFut
    if timeoutFut.read == false:
      error pool, " ", qe.url, " failed: timed out"
      qe.future.fail(newException(TimeoutError, "Request timed out"))
      return
  else:
    yield fut

  if fut.failed:
    error pool, " ", qe.url, " failed: ", fut.readError.msg.split("\n", 2)[0]
    qe.future.fail(fut.readError)
  else:
    info pool, " download complete: ", qe.url
    qe.future.complete(fut.read)

proc newAsyncHttpPool*(parallelism: Positive, userAgent: string): AsyncHttpPool =
  new(result)

  result.parallelism = parallelism
  result.clientAvailable = newAsyncEvent()
  for i in 0..<parallelism:
    let ahttp = newAsyncHttpClient(userAgent)
    result.clients.add ahttp

  var bindResult = result
  addEvent(result.clientAvailable) do (fd: AsyncFD) -> bool:
    while bindResult.clients.len > 0 and bindResult.queue.len > 0:
      var ahttp = bindResult.clients.pop()
      let qe = bindResult.queue.pop()
      asyncCheck downloadAndResolve(bindResult, ahttp, qe)
    false

proc getContent*(pool: AsyncHttpPool, url: string,
                 xferTimeout: Natural = 0, # total req time. use with care, this might cancel big transfers
                 initialDataTimeout: Natural = 12000, # timeout until first byte
                 progress: ProgressChangedProc[Future[void]] = nil): Future[string]  =
  let fut = newFuture[string]()
  info pool, " queued: ", url
  pool.queue.insert(QueueEntry(url: url, future: fut,
    xferTimeout: xferTimeout, initialDataTimeout: initialDataTimeout, progress: progress))
  if pool.clients.len > 0:
    pool.clientAvailable.trigger()
  return fut
