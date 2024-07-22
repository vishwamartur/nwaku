import std/[times, tables, options]
import chronos, chronicles
import ../waku_core

const DelayCacheCleanupPeriod = chronos.minutes(1)
const DefaultTimeSpan = times.initDuration(minutes = 30)

type TimeSpan = tuple[startTime: Timestamp, endTime: Timestamp]

type HashesTimestampCache* = ref object
  ## We keep this to enhance the queries that only use WHERE messagehash IN (...)
  ## These queries tend to need ~5 minutes. In this case, if the messageHashes used in the
  ## "IN" clause, then we will add timestamp filter so that those queries don't need to check
  ## the whole database.
  ##
  hashTimeTable: Table[WakuMessageHash, Timestamp]
  cacheCleanerHandle: Future[void]
  maxTimeToKeep: times.Duration
    ## The cache will keep message hashes for the last time span

proc new*(T: type HashesTimestampCache, maxTimeToKeep = DefaultTimeSpan): T =
  return HashesTimestampCache(maxTimeToKeep: maxTimeToKeep)

proc addHashTimestamp*(
    self: HashesTimestampCache, hash: WakuMessageHash, time: Timestamp
) =
  self.hashTimeTable[hash] = time

proc removeOlderThan(self: HashesTimestampCache, oldestTimeToKeep: Timestamp) =
  var hashesToRemove = newSeq[WakuMessageHash]()

  for hash, timestamp in self.hashTimeTable:
    if timestamp < oldestTimeToKeep:
      hashesToRemove.add(hash)

  for hash in hashesToRemove:
    self.hashTimeTable.del(hash)

proc cacheCleanKeeper(self: HashesTimestampCache) {.async.} =
  while true:
    let now = getTime()
    self.removeOlderThan((now - self.maxTimeToKeep).toUnix())
    await sleepAsync(DelayCacheCleanupPeriod)

proc startCacheCleaner*(self: HashesTimestampCache) =
  self.cacheCleanerHandle = self.cacheCleanKeeper()

proc stopCacheCleaner*(self: HashesTimestampCache) {.async.} =
  await noCancel(self.cacheCleanerHandle)

proc getTimeSpanForHashes*(
    self: HashesTimestampCache, hashes: seq[WakuMessageHash]
): Option[TimeSpan] =
  ## If all the passed hashes are considered by the in-memory cache,
  ## then this proc will return the time span associated to the passed hashes.
  if hashes.len <= 0:
    debug "error in containsAllHashes hashes.len <= 0"
    return none(TimeSpan)

  let firstHash = hashes[0]
  var startTime = self.hashTimeTable[firstHash]
  var endTime = self.hashTimeTable[firstHash]

  for index in 1 ..< hashes.len:
    let msgHash = hashes[index]
    if not self.hashTimeTable.contains(msgHash):
      debug "The hashes-cache doesn't contain", msg_hash = msgHash
      return none(TimeSpan)

    let time = self.hashTimeTable[msgHash]
    if time < startTime:
      startTime = time
    if time > endTime:
      endTime = time

  return some((startTime, endTime))
