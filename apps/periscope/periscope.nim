when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, os, times, strutils, sequtils, random],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/multihash,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/transports/wstransport,
  libp2p/nameresolving/dnsresolver,
  nimcrypto/utils
import
  ../../waku/common/utils/nat,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/wakuswitch,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/utils/time


logScope:
  topics = "periscope"


type SetupResult[T] = Result[T, string]


proc defaultListenAddress(): ValidIpAddress =
  (static ValidIpAddress.init("0.0.0.0"))

proc privateKey(hex: string): SetupResult[crypto.PrivateKey] =
  try:
    let key = SkPrivateKey.init(utils.fromHex(hex)).tryGet()
    ok(crypto.PrivateKey(scheme: Secp256k1, skkey: key))
  except:
    err("invalid private key: " & getCurrentExceptionMsg())


proc newNode(key: string): SetupResult[WakuNode] =
  ## Setup a basic Waku v2 node. No protocols are mounted yet.
  var serverAddrs: seq[ValidIpAddress]

  try:
    serverAddrs = @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
  except:
    return err(getCurrentExceptionMsg())

  # Support for DNS multiaddrs
  var dnsResolver: DnsResolver
  var nameServers: seq[TransportAddress]

  for ip in serverAddrs:
    nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

  dnsResolver = DnsResolver.new(nameServers)


  let port = Port(8080'u16)
  let
    ## `udpPort` is only supplied to satisfy underlying APIs but is not
    ## actually a supported transport for libp2p traffic.
    udpPort = port
    (extIp, extTcpPort, extUdpPort) = setupNat("any", clientId, port, udpPort)

    dns4DomainName = none(string)

    ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = extTcpPort


  var node: WakuNode

  try:
    node = WakuNode.new(
      nodeKey = privateKey(key).tryGet(),
      bindIp = defaultListenAddress(),
      bindPort = port,
      extIp=extIp,
      extPort=extPort,
      peerStorage=nil,
      maxConnections=50,
      nameResolver=dnsResolver
    )
  except:
    return err("failed to create waku node instance: " & getCurrentExceptionMsg())

  ok(node)


proc newClient(key: string): Future[SetupResult[WakuNode]] {.async.} =
  debug "1/3 Initializing node"

  var node: WakuNode

  let newNodeRes = newNode(key=key)
  if newNodeRes.isok():
    node = newNodeRes.get()
  else:
    return err("Node initialization failed: " &  $newNodeRes.error)


  debug "2/3 Mounting protocols"

  try:
    mountStoreClient(node)
  except:
    return err("failed to set node waku store peer: " & getCurrentExceptionMsg())


  debug "3/3 Starting node"

  try:
    await node.start()
  except:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  return ok(node)


type QueryResult = Result[(times.Duration, times.Duration, HistoryResponse), string]

proc sendQuery(client: WakuNode, request: HistoryQuery, node: string, pageSize: int): Future[QueryResult] {.async.} =
  let remotePeerInfo = parseRemotePeerInfo(node)

  var req = request # copy
  req.pageSize = pageSize.uint64


  let start = getTime()

  let queryRes = await client.query(req, peer=remotePeerInfo)
  if queryRes.isErr():
    return err("request failed: " & queryRes.error)

  let duration = getTime() - start

  let response = queryRes.get()

  return ok((duration, duration, response))


proc sendQueryChain(client: WakuNode, request: HistoryQuery, node: string, pageSize, total: int): Future[QueryResult] {.async.} =
  let remotePeerInfo = parseRemotePeerInfo(node)

  var minDuration: times.Duration = high(times.Duration)
  var maxDuration: times.Duration = default(times.Duration)

  var messages = newSeq[WakuMessage]()

  # ------------

  var req = request # copy
  req.pageSize = pageSize.uint64

  while true:
    let start = getTime()

    let queryRes = await client.query(req, peer=remotePeerInfo)
    if queryRes.isErr():
      return err("request failed: " & queryRes.error)

    let duration = getTime() - start

    minDuration = min(minDuration, duration)
    maxDuration = max(maxDuration, duration)


    let response = queryRes.get()


    messages = concat(messages, response.messages)

    if messages.len >= total:
      break

    if response.cursor.isNone():
      break

    req.cursor = response.cursor

  return ok((minDuration, maxDuration, HistoryResponse(messages: messages)))


proc sendBatchedQueries(client: WakuNode, request: HistoryQuery, node: string, batchSize: int, total: int,
                        startTime, endTime: float): Future[seq[QueryResult]] {.async.} =
  # let contentTopics = @["/waku/1/0xaf1076d0/rfc26", "/waku/1/0x4d75788e/rfc26", "/waku/1/0x6cad2225/rfc26", "/waku/1/0x958ded08/rfc26",
  #                       "/waku/1/0x5af863b6/rfc26", "/waku/1/0xeaebfe8a/rfc26", "/waku/1/0x0041e88f/rfc26", "/waku/1/0x0f8d91da/rfc26",
  #                       "/waku/1/0x5fb5d269/rfc26", "/waku/1/0x6cad2225/rfc26", "/waku/1/0xc3693ce2/rfc26", "/waku/1/0x2da8da5f/rfc26",
  #                       "/waku/1/0xdc8fd8c8/rfc26", "/waku/1/0x08945265/rfc26"]
  let contentTopics = @["/waku/1/0x9aac432a/rfc26", "/waku/1/0x96d84dee/rfc26", "/waku/1/0xc2e6cc37/rfc26", "/waku/1/0xe50bd0e5/rfc26",
                        "/waku/1/0x4a0c385d/rfc26", "/waku/1/0xfc5cb630/rfc26", "/waku/1/0xfc3672fc/rfc26", "/waku/1/0x8fc857e1/rfc26",
                        "/waku/1/0x6f669ec1/rfc26", "/waku/1/0x92eeffe1/rfc26", "/waku/1/0x00c78243/rfc26", "/waku/1/0x9a57e990/rfc26",
                        "/waku/1/0x04b6bb8d/rfc26", "/waku/1/0xdabb40f9/rfc26", "/waku/1/0xcc815d56/rfc26", "/waku/1/0x23f69315/rfc26",
                        "/waku/1/0xec9354d9/rfc26", "/waku/1/0x44ad4cbc/rfc26", "/waku/1/0x4d7ec927/rfc26", "/waku/1/0x430e90dc/rfc26",
                        "/waku/1/0xdfed4dbf/rfc26"]

  var batch = newSeq[Future[QueryResult]]()
  for i in 1..batchSize:
    let
      startTime = startTime - (10 * float(60 - rand(120)) * 1_000_000_000)
      endTime = endTime - (10 * 60 - float(rand(120)) * 1_000_000_000)

    var requestCopy = request # copy
    requestCopy.contentTopics = @[sample(contentTopics), sample(contentTopics), sample(contentTopics)]
    requestCopy.startTime = some(Timestamp(startTime))
    requestCopy.endTime = some(Timestamp(endTime))

    let req = if total <= 100: client.sendQuery(requestCopy, node, total)
                  else: client.sendQueryChain(requestCopy, node, 50, total)
    batch.add(req)

  await allFutures(batch)

  try:
    let responses = batch.mapIt(it.read())
    return responses
  except:
    error "failure in a request batch", error=getCurrentExceptionMsg()
    try:
      return batch.filterIt(it.completed()).mapIt(it.read())
    except:
      return @[]


proc main(storenode: string, batchSize, loopCount: int, timeSpan, timeOffset: float64, totalMessages: int): Future[int] {.async.} =
  randomize(getTime().toUnix())


  let key = "8473bba3b648edbe2fc0e10b7005329fd797cef596a1217fda4c7394cedabd37"
  debug "node key", key=key


  debug "Setup client"

  var client: WakuNode  # This is the node we're going to setup using the conf

  let initClientRes = await newClient(key=key)
  if initClientRes.isok():
    client = initClientRes.get()
  else:
    error "Node initialization failed. Quitting.", error=initClientRes.error
    return 1

  debug "Setup finished"

  let now = epochTime() * 1_000_000_000
  let
    startTime = now - (timeOffset * 1_000_000_000)  - ((timeSpan + 120'f64) * 1_000_000_000'f64)
    endTime = now - (timeOffset * 1_000_000_000)

  let request = HistoryQuery(
    pubsubTopic: some("/waku/2/default-waku/proto"),
    # contentTopics: @["/waku/1/0xd6861a81/rfc26"],
    # cursor: some(HistoryCursor(
    #   pubsubTopic: "/waku/2/default-waku/proto",
    #   senderTime: Timestamp(1666380751000000000),
    #   storeTime: Timestamp(1666380751000000000),
    #   # digest: "0x6e88e64433b169865ba45faafe77ee464b9a9eaacd144778af6998e11f6cc"
    #   digest: MessageDigest(data: [byte 110, 136, 230, 68, 51, 177, 105, 134, 91, 164, 95, 170, 254, 119, 238, 70, 75, 154, 158, 10, 10, 205, 20, 71, 120, 175, 105, 152, 14, 17, 246, 204]),
    # )),
    startTime: some(Timestamp(startTime)),
    endTime: some(Timestamp(endTIme)),
    pageSize: 1,
    ascending: true
  )


  for iteration in 1..loopCount:
    let queryBatch = await client.sendBatchedQueries(request, storenode, batchSize, totalMessages,
                                                     startTime, endTime)

    for batchNumber, queryRes in queryBatch:
      if queryRes.isErr():
        error "query response", iteration=iteration, batch=batchNumber+1, error=queryRes.error
        continue

      let (minDuration, maxDuration, response) = queryRes.get()

      let minMs = minDuration.inNanoseconds().float / 1_000_000'f64
      let maxMs = maxDuration.inNanoseconds().float / 1_000_000'f64
      info "query response", iteration=iteration, batch=batchNumber+1, count=response.messages.len, min_duration=minMs, max_duration=maxMs
      # info "query response topics", contentTopics=response.messages.mapIt(it.contentTopic).deduplicate()

    await sleepAsync(chronos.seconds(1))

  return 0


when isMainModule:

  # let peer = "/dns4/node-02.gc-us-central1-a.status.prod.statusim.net/tcp/30303/p2p/16Uiu2HAmDQugwDHM3YeUp86iGjrUvbdw3JPRgikC7YoGBsT2ymMg"
  # let peer = "/dns4/node-02.do-ams3.status.prod.statusim.net/tcp/30303/p2p/16Uiu2HAmSve7tR5YZugpskMv2dmJAsMUKmfWYEKRXNUxRaTCnsXV"

  let storeNode = paramStr(1)
  let batchSize = parseInt(paramStr(2))
  let loopCount = parseInt(paramStr(3))
  let timeSpan = parseFloat(paramStr(4))
  let timeOffset = parseFloat(paramStr(5))
  let totalMessages = parseInt(paramStr(6))

  let rc = waitFor main(storeNode, batchSize, loopCount, timeSpan, timeOffset, totalMessages)

  quit(rc)

# ./build/wakunode2 --ports-shift=10 --metrics-logging=false --rpc=false --nodekey=c5b00947dce061e55bb2061fd17d8c1012a7dc0499cc8883c38cb2234fbc1d93 --store=true --store-message-db-migration=false --store-message-db-url='sqlite://./tools/store.sqlite3' --store-message-retention-policy=none --log-level=DEBUG

# nim c -r --parallelBuild:12 --nimcache:nimcache -d:chronicles_log_level=DEBUG tools/periscope/periscope.nim "/ip4/127.0.0.1/tcp/60010/p2p/16Uiu2HAm9EVQf54eCk651fhRyzUUcC1MkxMmU1Naax3F5QSRs6d6"
