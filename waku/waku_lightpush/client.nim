{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand
import
  ../node/peer_manager,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku lightpush v2 client"

type WakuLightPushClient* = ref object
  peerManager*: PeerManager
  rng*: ref rand.HmacDrbgContext

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

proc sendPushRequest(
    wl: WakuLightPushClient, req: LightPushRequest, peer: PeerId | RemotePeerInfo
): Future[WakuLightPushResult] {.async, gcsafe.} =
  let connection = (await wl.peerManager.dialPeer(peer, WakuLightPushCodec)).valueOr:
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return
      lightpushResultInternalError(dialFailure & ": " & $peer & " is not accessible")

  await connection.writeLP(req.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    error "Failed to read responose from peer", exception = getCurrentExceptionMsg()
    return
      lightpushResultInternalError("Exception reading: " & getCurrentExceptionMsg())

  let response = LightpushResponse.decode(buffer).valueOr:
    error "failed to decode response"
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return lightpushResultInternalError(decodeRpcFailure)

  if response.requestId != req.requestId:
    error "response failure, requestId mismatch",
      requestId = req.requestId, responseReqeustId = response.requestId
    return lightpushResultInternalError("response failure, requestId mismatch")

  return toPushResult(response)

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: Option[PubsubTopic] = none(PubsubTopic),
    message: WakuMessage,
    peer: PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubSubTopic: pubSubTopic, message: message
  )
  return await wl.sendPushRequest(pushRequest, peer)
