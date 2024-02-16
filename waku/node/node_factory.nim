import
  chronicles

import
  ../waku_enr/sharding

## Peer persistence

const PeerPersistenceDbUrl = "peers.db"
proc setupPeerStorage(): Result[Option[WakuPeerStorage], string] =
  let db = ? SqliteDatabase.new(PeerPersistenceDbUrl)

  ? peer_store_sqlite_migrations.migrate(db)

  let res = WakuPeerStorage.new(db)
  if res.isErr():
    return err("failed to init peer store" & res.error)

  ok(some(res.value))

## Retrieve dynamic bootstrap nodes (DNS discovery)

proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool,
                                    dnsDiscoveryUrl: string,
                                    dnsDiscoveryNameServers: seq[IpAddress]):
                                    Result[seq[RemotePeerInfo], string] =

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

proc setupNode*(conf: WakuNodeConf): Result[WakuNode, string] =
  var peerStoreOpt: Option[WakuPeerStorage]
  
  let key =
    if conf.nodeKey.isSome():
      conf.nodeKey.get()
    else:
      crypto.PrivateKey.random(Secp256k1, crypto.newRng()[]).valueOr:
        error "Failed to generate key", error=error
        return err("Failed to generate key " & error)
  
  let netConfig = networkConfiguration(conf, clientId).valueOr:
    error "failed to create internal config", error=error
    return err("failed to create internal config " & error)

  let record = enrConfiguration(conf, netConfig, key).valueOr:
    error "failed to create record", error=error
    return err("failed to create record " & error)

  if isClusterMismatched(record, conf.clusterId):
    error "cluster id mismatch configured shards"
    return err("cluster id mismatch configured shards")
  
  debug "1/7 Setting up storage"

  ## Peer persistence
  if conf.peerPersistence:
    let peerStore = setupPeerStorage().valueOr:
      error "1/7 Setting up storage failed", error = "failed to setup peer store " & error
      return err("Setting up storage failed " & error)
    peerStoreOpt = some(peerStore)

  debug "2/7 Retrieve dynamic bootstrap nodes"

  let dynamicBootstrapNodes = retrieveDynamicBootstrapNodes(conf.dnsDiscovery,
                                                            conf.dnsDiscoveryUrl,
                                                            conf.dnsDiscoveryNameServers).valueOr:
    error "2/7 Retrieving dynamic bootstrap nodes failed", error = error
    return err("Retrieving dynamic bootstrap nodes failed " & error)

  debug "3/7 Initializing node"

  let node = initNode(conf, netConf, app.rng, key, record, peerStoreOpt, 
                      dynamicBootstrapNodes).valueOr:
    error "3/7 Initializing node failed", error = error
    return err("Initializing node failed " & error)
  
  # TO DO: see discv5 as in setupWakuApp

  


  