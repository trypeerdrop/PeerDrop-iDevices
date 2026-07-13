// app.js — PeerDrop orchestrator (application layer).
//
// Depends only on PeerDropProtocol (the abstraction), never on bare-rpc,
// command integers, or JSON framing. Responsibilities: identity, swarm,
// peer lifecycle, transfers. All native I/O goes through `this.proto`.

const Hyperswarm = require('hyperswarm')
const Protomux   = require('protomux')
const c          = require('compact-encoding')
const os         = require('bare-os')

const { PeerDropProtocol, COMMANDS } = require('./protocol')
const store  = require('./store')
const TransferManager = require('./transfers')

class PeerDrop {
  constructor () {
    this.swarm              = null
    this.discoveryPublicKey = null
    this.peers              = new Map()
    this.deviceName         = null
    this.swarmStarted       = false

    // Protocol layer — the only thing that talks to native.
    this.proto = new PeerDropProtocol(BareKit.IPC)
    this._registerHandlers()

    // TransferManager already uses COMMANDS.* ids internally; hand it the
    // protocol's generic emit so it stays unchanged and still decoupled.
    this.transfers = new TransferManager(
      (command, payload) => this.proto.emit(command, payload),
      () => store.getDownloadPath()
    )

    this._init()
  }

  // ── Inbound handlers (native → JS), all typed ──────────────────────────────

  _registerHandlers () {
    this.proto.onConnectPeer(async ({ peerID }) => {
      await this._connectToPeer(peerID)          // throws → protocol sends error reply
    })

    this.proto.onSetDownloadPath(({ downloadPath }) => {
      store.setDownloadPath(downloadPath)
    })

    this.proto.onForgetPeer(({ peerDiscoveryKey }) => {
      this._forgetPeer(peerDiscoveryKey)
    })

    this.proto.onSendFile(({ filePath, peerId }) => {
      this._sendFile(filePath, peerId).catch(err =>
        console.error('[peerdrop] send error:', err.message)
      )
    })
  }

  // ── Boot ────────────────────────────────────────────────────────────────────

  async _init () {
    const argv = (typeof Bare !== 'undefined' && Bare.argv) || []
    this.deviceName = argv[1] || null

    const { discoveryPublicKey } = await store.loadIdentity()
    this.discoveryPublicKey = discoveryPublicKey

    this.proto.emitReady({
      peerID:       this.discoveryPublicKey.toString('hex'),
      downloadPath: store.getDownloadPath()
    })
    this._emitSavedPeers()

    // Fallback: start the swarm even if native never sets a device name.
    setTimeout(() => this._startSwarm(), 1500)
  }

  _startSwarm () {
    if (this.swarmStarted) return
    this.swarmStarted = true

    this.swarm = new Hyperswarm()
    this.swarm.on('connection', (conn, info) => this._onConnection(conn, info))
    this.swarm.join(this.discoveryPublicKey, { server: true, client: true })

    for (const peer of store.loadSavedPeers()) this._joinTopic(peer.discoveryKey)
  }

  // ── Peer management ───────────────────────────────────────────────────────

  async _connectToPeer (discoveryKeyHex) {
    if (!/^[0-9a-f]{64}$/i.test(discoveryKeyHex)) {
      throw new Error('Invalid Peer ID — must be 64 hex characters')
    }
    store.upsertSavedPeer(discoveryKeyHex)
    const discovery = this._joinTopic(discoveryKeyHex)
    this._emitSavedPeers()
    if (discovery) await discovery.flushed()
    if (this.swarm) await this.swarm.flush()
  }

  _forgetPeer (discoveryKeyHex) {
    try { this.swarm.leave(Buffer.from(discoveryKeyHex, 'hex')) } catch (_) {}
    store.removeSavedPeer(discoveryKeyHex)
    this._emitSavedPeers()
  }

  _joinTopic (hex) {
    if (!this.swarm) this._startSwarm()
    return this.swarm.join(Buffer.from(hex, 'hex'), { server: false, client: true })
  }

  // ── Connection setup ──────────────────────────────────────────────────────

  _onConnection (conn, info) {
    const noiseKeyHex = info.publicKey.toString('hex')
    const mux         = new Protomux(conn)

    this.transfers.pairTransferChannels(mux, noiseKeyHex)

    this.peers.set(noiseKeyHex, {
      mux, controlCh: null,
      discoveryKey: null, displayName: null, platform: null, isOwnDevice: false
    })

    const controlCh = mux.createChannel({
      protocol: 'peerdrop/control',
      messages: [
        { encoding: c.json, onmessage: (msg) => this._onControlMessage(mux, noiseKeyHex, msg) }
      ],
      onopen: () => {
        controlCh.messages[0].send({
          type:         'handshake',
          discoveryKey: this.discoveryPublicKey.toString('hex'),
          displayName:  this.deviceName || os.hostname(),
          platform:     os.platform()
        })
      },
      onclose: () => {
        const peer = this.peers.get(noiseKeyHex)
        this.peers.delete(noiseKeyHex)
        this.proto.emitPeerDisconnected({
          noiseKey:     noiseKeyHex,
          discoveryKey: peer?.discoveryKey ?? null
        })
      }
    })

    this.peers.get(noiseKeyHex).controlCh = controlCh
    controlCh.open()

    conn.on('error', (err) => console.error('[peerdrop] connection error:', err.message))
  }

  // ── Control message router ────────────────────────────────────────────────

  _onControlMessage (mux, noiseKeyHex, msg) {
    switch (msg.type) {
      case 'handshake': {
        const { discoveryKey, displayName, platform } = msg
        const isOwnDevice = discoveryKey === this.discoveryPublicKey.toString('hex')
        const peer = this.peers.get(noiseKeyHex)
        if (peer) {
          peer.discoveryKey = discoveryKey
          peer.displayName  = displayName
          peer.platform     = platform
          peer.isOwnDevice  = isOwnDevice
        }
        if (!isOwnDevice) {
          store.upsertSavedPeer(discoveryKey, { displayName, platform, lastSeen: Date.now() })
          this._emitSavedPeers()
        }
        this.proto.emitPeerConnected({
          noiseKey: noiseKeyHex, discoveryKey, displayName, platform, isOwnDevice
        })
        break
      }

      case 'batchStart': {
        this.transfers.onBatchStart(msg, noiseKeyHex)
        this.proto.emitTransferStarted({
          transferId:  msg.batchId,
          fileName:    msg.dirName,
          fileSize:    msg.totalSize,
          fileCount:   msg.fileCount,
          peerId:      noiseKeyHex,
          direction:   'receiving',
          isDirectory: true
        })
        break
      }

      case 'fileOffer': {
        const info = this.transfers.onOffer(msg, noiseKeyHex)
        if (info) {
          this.proto.emitTransferStarted({
            ...info, direction: 'receiving', isDirectory: false, fileCount: 0
          })
        }
        break
      }

      case 'batchComplete':
        this.transfers.onBatchComplete(msg)
        break
    }
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  async _sendFile (filePath, discoveryKey) {
    const peer = this._livePeer(discoveryKey)
    if (!peer) throw new Error('Peer not connected: ' + discoveryKey)
    this.transfers.offer(filePath, peer.mux, peer.controlCh, peer.noiseKey)
  }

  _livePeer (discoveryKey) {
    for (const [noiseKey, peer] of this.peers.entries()) {
      if (peer.discoveryKey === discoveryKey) return { ...peer, noiseKey }
    }
    return null
  }

  _emitSavedPeers () {
    this.proto.emitSavedPeers({ peers: store.loadSavedPeers() })
  }
}

new PeerDrop()
