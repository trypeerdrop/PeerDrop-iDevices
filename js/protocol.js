// protocol.js — PeerDrop IPC protocol layer (JS side).
//
// SOLID split: this module owns EVERYTHING about how JS talks to native —
// command IDs, (de)serialization, request vs event semantics, and routing.
// The application layer (app.js) never touches bare-rpc, command integers,
// or JSON framing again; it calls typed methods and registers typed handlers.
//
//   Single Responsibility : encode/decode + route typed messages. Nothing else.
//   Open/Closed           : add a command in COMMANDS + a wrapper; nothing else changes.
//   Dependency Inversion  : app.js depends on this abstraction, not on bare-rpc.

const RPC = require('bare-rpc')

// ── Command table — the single source of truth on the JS side ───────────────
// (mirrors Commands.swift / Cmd.kt). Kept private to this module.
const COMMANDS = {
  // JS → native events (fire-and-forget)
  READY:             1,
  PEER_CONNECTED:    2,
  PEER_DISCONNECTED: 3,
  TRANSFER_STARTED:  4,
  TRANSFER_PROGRESS: 5,
  TRANSFER_COMPLETE: 6,
  ERROR:             7,
  SAVED_PEERS:       11,
  // native → JS requests (expect a reply)
  SEND_FILE:         8,
  CONNECT_PEER:      9,
  SET_DOWNLOAD_PATH: 10,
  FORGET_PEER:       12,
  SET_DEVICE_NAME:   13
}

// Which inbound commands are fire-and-forget (no reply) vs request/response.
const SEND_ONLY_INBOUND = new Set([COMMANDS.SEND_FILE])

/**
 * PeerDropProtocol wraps a single bare-rpc instance over BareKit.IPC and
 * exposes a typed API. It knows nothing about swarms, transfers, or UI.
 */
class PeerDropProtocol {
  /**
   * @param {object} ipc  - BareKit.IPC
   */
  constructor (ipc) {
    this._rpc = new RPC(ipc, (req) => this._dispatch(req))
    this._handlers = new Map()   // command id → async (payload) => result
  }

  // ── Outbound: JS → native events (typed, fire-and-forget) ─────────────────

  emitReady            (p) { this._event(COMMANDS.READY, p) }
  emitPeerConnected    (p) { this._event(COMMANDS.PEER_CONNECTED, p) }
  emitPeerDisconnected (p) { this._event(COMMANDS.PEER_DISCONNECTED, p) }
  emitTransferStarted  (p) { this._event(COMMANDS.TRANSFER_STARTED, p) }
  emitTransferProgress (p) { this._event(COMMANDS.TRANSFER_PROGRESS, p) }
  emitTransferComplete (p) { this._event(COMMANDS.TRANSFER_COMPLETE, p) }
  emitError            (p) { this._event(COMMANDS.ERROR, p) }
  emitSavedPeers       (p) { this._event(COMMANDS.SAVED_PEERS, p) }

  // Generic typed emit for internal modules that already carry a COMMANDS id
  // (e.g. TransferManager). Still goes through the one framing path.
  emit (command, payload) { this._event(command, payload) }

  // ── Inbound: native → JS (register typed handlers) ────────────────────────
  // Handlers for request commands may return a payload (sent as the reply) or
  // throw (sent as an error reply). Handlers for send-only commands return void.

  onSendFile        (fn) { this._handlers.set(COMMANDS.SEND_FILE, fn) }
  onConnectPeer     (fn) { this._handlers.set(COMMANDS.CONNECT_PEER, fn) }
  onSetDownloadPath (fn) { this._handlers.set(COMMANDS.SET_DOWNLOAD_PATH, fn) }
  onForgetPeer      (fn) { this._handlers.set(COMMANDS.FORGET_PEER, fn) }
  onSetDeviceName   (fn) { this._handlers.set(COMMANDS.SET_DEVICE_NAME, fn) }

  // ── Internals ─────────────────────────────────────────────────────────────

  _event (command, payload) {
    this._rpc.event(command).send(this._encode(payload))
  }

  _encode (payload) {
    return Buffer.from(JSON.stringify(payload ?? {}))
  }

  _decode (req) {
    return req.data ? JSON.parse(req.data.toString()) : {}
  }

  async _dispatch (req) {
    const handler = this._handlers.get(req.command)
    const payload = this._decode(req)

    // Fire-and-forget inbound (IncomingEvent has no reply()).
    if (typeof req.reply !== 'function' || SEND_ONLY_INBOUND.has(req.command)) {
      if (handler) {
        try { await handler(payload) }
        catch (err) { console.error('[protocol] handler error:', err.message) }
      }
      return
    }

    // Request/response inbound — must reply exactly once.
    if (!handler) { req.reply(); return }
    try {
      const result = await handler(payload)
      req.reply(result ? this._encode(result) : undefined)
    } catch (err) {
      req.reply(this._encode({ error: err.message }))
    }
  }
}

module.exports = { PeerDropProtocol, COMMANDS }
