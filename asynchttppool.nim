import std/[asyncdispatch, httpclient, logging, strutils]
from std/net import TimeoutError

type
  QueueEntry = tuple
    url: string
    future: Future[string]
    timeout: Natural # seconds

  AsyncHttpPool* = ref object
    parallelism: Positive
    clientAvailable: AsyncEvent
    clients: seq[AsyncHttpClient]
    queue: seq[QueueEntry]
    inflight: seq[QueueEntry]

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

  ahttp.onProgressChanged = proc(total, progress, speed: BiggestInt) {.async.} =
    notice qe.url, ": ", progress, " of ", total, ", current rate: ", speed div 1000, "kb/s"

  notice pool, " starting download: ", qe.url
  let fut = ahttp.getContent(qe.url)
  if qe.timeout > 0:
    let timeoutFut = withTimeout(fut, qe.timeout)
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
    notice pool, " download complete: ", qe.url
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

proc getContent*(pool: AsyncHttpPool, url: string, timeout: Natural = 0): Future[string]  =
  let fut = newFuture[string]()
  info pool, " queued: ", url
  pool.queue.insert((url, fut, timeout))
  if pool.clients.len > 0:
    pool.clientAvailable.trigger()
  return fut
