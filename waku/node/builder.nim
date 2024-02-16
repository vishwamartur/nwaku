when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  stew/shims/net,
  chronicles,
  libp2p/crypto/crypto,
  libp2p/builders,
  libp2p/nameresolving/[nameresolver, dnsresolver],
  libp2p/transports/wstransport
import
  ../../apps/wakunode2/external_config, # should we move the wakunode configs out of apps directory?
  ../waku_enr,
  ../waku_discv5,
  ./config,
  ./peer_manager,
  ./waku_node,
  ./waku_switch,
  ./peer_manager/peer_store/waku_peer_storage

type
  WakuNodeBuilder* = object
    # General
    nodeRng: Option[ref crypto.HmacDrbgContext]
    nodeKey: Option[crypto.PrivateKey]
    netConfig: Option[NetConfig]
    record: Option[enr.Record]

    # Peer storage and peer manager
    peerStorage: Option[PeerStorage]
    peerStorageCapacity: Option[int]

    # Peer manager config
    maxRelayPeers: Option[int]
    colocationLimit: int
    shardAware: bool

    # Libp2p switch
    switchMaxConnections: Option[int]
    switchNameResolver: Option[NameResolver]
    switchAgentString: Option[string]
    switchSslSecureKey: Option[string]
    switchSslSecureCert: Option[string]
    switchSendSignedPeerRecord: Option[bool]

  WakuNodeBuilderResult* = Result[void, string]


## Init

proc init*(T: type WakuNodeBuilder): WakuNodeBuilder =
  WakuNodeBuilder()


## General

proc withRng*(builder: var WakuNodeBuilder, rng: ref crypto.HmacDrbgContext) =
  builder.nodeRng = some(rng)

proc withNodeKey*(builder: var WakuNodeBuilder, nodeKey: crypto.PrivateKey) =
  builder.nodeKey = some(nodeKey)

proc withRecord*(builder: var WakuNodeBuilder, record: enr.Record) =
  builder.record = some(record)

proc withNetworkConfiguration*(builder: var WakuNodeBuilder, config: NetConfig) =
  builder.netConfig = some(config)

proc withNetworkConfigurationDetails*(builder: var WakuNodeBuilder,
          bindIp: IpAddress,
          bindPort: Port,
          extIp = none(IpAddress),
          extPort = none(Port),
          extMultiAddrs = newSeq[MultiAddress](),
          wsBindPort: Port = Port(8000),
          wsEnabled: bool = false,
          wssEnabled: bool = false,
          wakuFlags = none(CapabilitiesBitfield),
          dns4DomainName = none(string)): WakuNodeBuilderResult {.
  deprecated: "use 'builder.withNetworkConfiguration()' instead".} =
  let netConfig = ? NetConfig.init(
    bindIp = bindIp,
    bindPort = bindPort,
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    wakuFlags = wakuFlags,
    dns4DomainName = dns4DomainName,
  )
  builder.withNetworkConfiguration(netConfig)
  ok()


## Peer storage and peer manager

proc withPeerStorage*(builder: var WakuNodeBuilder, peerStorage: PeerStorage, capacity = none(int)) =
  if not peerStorage.isNil():
    builder.peerStorage = some(peerStorage)

  builder.peerStorageCapacity = capacity

proc withPeerManagerConfig*(builder: var WakuNodeBuilder,
                            maxRelayPeers = none(int),
                            shardAware = false) =
  builder.maxRelayPeers = maxRelayPeers
  builder.shardAware = shardAware

proc withColocationLimit*(builder: var WakuNodeBuilder,
                          colocationLimit: int) =
  builder.colocationLimit = colocationLimit

## Waku switch

proc withSwitchConfiguration*(builder: var WakuNodeBuilder,
                              maxConnections = none(int),
                              nameResolver: NameResolver = nil,
                              sendSignedPeerRecord = false,
                              secureKey = none(string),
                              secureCert = none(string),
                              agentString = none(string)) =
  builder.switchMaxConnections = maxConnections
  builder.switchSendSignedPeerRecord = some(sendSignedPeerRecord)
  builder.switchSslSecureKey = secureKey
  builder.switchSslSecureCert = secureCert
  builder.switchAgentString = agentString

  if not nameResolver.isNil():
    builder.switchNameResolver = some(nameResolver)

## Build

proc build*(builder: WakuNodeBuilder): Result[WakuNode, string] =
  var rng: ref crypto.HmacDrbgContext
  if builder.nodeRng.isNone():
    rng = crypto.newRng()
  else:
    rng = builder.nodeRng.get()

  if builder.nodeKey.isNone():
    return err("node key is required")

  if builder.netConfig.isNone():
    return err("network configuration is required")

  if builder.record.isNone():
    return err("node record is required")

  var switch: Switch
  try:
    switch = newWakuSwitch(
      privKey = builder.nodekey,
      address = builder.netConfig.get().hostAddress,
      wsAddress = builder.netConfig.get().wsHostAddress,
      transportFlags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay},
      rng = rng,
      maxConnections = builder.switchMaxConnections.get(builders.MaxConnections),
      wssEnabled = builder.netConfig.get().wssEnabled,
      secureKeyPath = builder.switchSslSecureKey.get(""),
      secureCertPath = builder.switchSslSecureCert.get(""),
      nameResolver = builder.switchNameResolver.get(nil),
      sendSignedPeerRecord = builder.switchSendSignedPeerRecord.get(false),
      agentString = builder.switchAgentString,
      peerStoreCapacity = builder.peerStorageCapacity,
      services = @[Service(getAutonatService(rng))],
    )
  except CatchableError:
    return err("failed to create switch: " & getCurrentExceptionMsg())

  let peerManager = PeerManager.new(
    switch = switch,
    storage = builder.peerStorage.get(nil),
    maxRelayPeers = builder.maxRelayPeers,
    colocationLimit = builder.colocationLimit,
    shardedPeerManagement = builder.shardAware,
  )

  var node: WakuNode
  try:
    node = WakuNode.new(
      netConfig = builder.netConfig.get(),
      enr = builder.record.get(),
      switch = switch,
      peerManager = peerManager,
      rng = rng,
    )
  except Exception:
    return err("failed to build WakuNode instance: " & getCurrentExceptionMsg())

  ok(node)

## Init waku node instance
proc initNode*(conf: WakuNodeConf,
              netConfig: NetConfig,
              rng: ref HmacDrbgContext,
              nodeKey: crypto.PrivateKey,
              record: enr.Record,
              peerStore: Option[WakuPeerStorage],
              dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): Result[WakuNode, string] =

  ## Setup a basic Waku v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  var dnsResolver: DnsResolver
  if conf.dnsAddrs:
    # Support for DNS multiaddrs
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    dnsResolver = DnsResolver.new(nameServers)

  var node: WakuNode

  let pStorage = if peerStore.isNone(): nil
                 else: peerStore.get()

  # Build waku node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(nodekey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withPeerStorage(pStorage, capacity = conf.peerStoreCapacity)
  builder.withSwitchConfiguration(
      maxConnections = some(conf.maxConnections.int),
      secureKey = some(conf.websocketSecureKeyPath),
      secureCert = some(conf.websocketSecureCertPath),
      nameResolver = dnsResolver,
      sendSignedPeerRecord = conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
      agentString = some(conf.agentString)
  )
  builder.withColocationLimit(conf.colocationLimit)
  builder.withPeerManagerConfig(
    maxRelayPeers = conf.maxRelayPeers,
    shardAware = conf.relayShardedPeerManagement,)

  node = ? builder.build().mapErr(proc (err: string): string = "failed to create waku node instance: " & err)

  ok(node)
