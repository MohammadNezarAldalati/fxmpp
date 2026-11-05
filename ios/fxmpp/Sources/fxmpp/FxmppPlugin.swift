#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif
import XMPPFramework

/// KissXML aliases `NSXMLElement`/`XMLElement` → `DDXMLElement` only on iOS
/// (`#if TARGET_OS_IPHONE` in KissXML's `DDXML.h`). On macOS those names are
/// Foundation's own classes, while `DDXMLElement` is a separate class that
/// `XMPPStream.send` and `addChild` reject. Use each platform's native element
/// type; the `NSXMLElement (XMPP)` category supplies `init(name:xmlns:)`,
/// `init(xmlString:)` and `addAttribute(withName:stringValue:)` on both.
#if os(macOS)
public typealias XMPPXMLElement = XMLElement
#else
public typealias XMPPXMLElement = DDXMLElement
#endif

public class FxmppPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var connectionStateEventChannel: FlutterEventChannel?
    private var messageEventChannel: FlutterEventChannel?
    private var presenceEventChannel: FlutterEventChannel?
    private var iqEventChannel: FlutterEventChannel?
    private var mucEventChannel: FlutterEventChannel?
    
    private var connectionStateStreamHandler: ConnectionStateStreamHandler?
    private var messageStreamHandler: MessageStreamHandler?
    private var presenceStreamHandler: PresenceStreamHandler?
    private var iqStreamHandler: IqStreamHandler?
    private var mucEventStreamHandler: MucEventStreamHandler?
    
    private var xmppStream: XMPPStream?
    private var xmppMUC: XMPPMUC?
    
    private var joinedRooms: [String: XMPPRoom] = [:]
    private var isConnected = false
    private var password: String?
    private var allowSelfSignedCertificates = false
    /// The `connect` call still waiting for the outcome of this stream. It is
    /// settled from the stream delegate (authenticated → `true`, SASL failure →
    /// `AUTH_FAILED`, socket failure → `CONNECTION_ERROR`) so Dart resolves only
    /// once the session is usable, exactly as Android does after `login()`.
    private var pendingConnectResult: FlutterResult?
    
    /// Resolves the binary messenger across platforms: on macOS `messenger` is a
    /// property, on iOS it is a method.
    private static func binaryMessenger(from registrar: FlutterPluginRegistrar) -> FlutterBinaryMessenger {
        #if canImport(FlutterMacOS)
        return registrar.messenger
        #else
        return registrar.messenger()
        #endif
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "fxmpp", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        let instance = FxmppPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        // Set up event channels
        instance.setupEventChannels(registrar: registrar)
    }
    
    private func setupEventChannels(registrar: FlutterPluginRegistrar) {
        // Connection state event channel
        connectionStateEventChannel = FlutterEventChannel(name: "fxmpp/connection_state", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        connectionStateStreamHandler = ConnectionStateStreamHandler()
        connectionStateEventChannel?.setStreamHandler(connectionStateStreamHandler)
        
        // Message event channel
        messageEventChannel = FlutterEventChannel(name: "fxmpp/messages", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        messageStreamHandler = MessageStreamHandler()
        messageEventChannel?.setStreamHandler(messageStreamHandler)
        
        // Presence event channel
        presenceEventChannel = FlutterEventChannel(name: "fxmpp/presence", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        presenceStreamHandler = PresenceStreamHandler()
        presenceEventChannel?.setStreamHandler(presenceStreamHandler)
        
        // IQ event channel
        iqEventChannel = FlutterEventChannel(name: "fxmpp/iq", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        iqStreamHandler = IqStreamHandler()
        iqEventChannel?.setStreamHandler(iqStreamHandler)
        
        // MUC event channel
        mucEventChannel = FlutterEventChannel(name: "fxmpp/muc_events", binaryMessenger: FxmppPlugin.binaryMessenger(from: registrar))
        mucEventStreamHandler = MucEventStreamHandler()
        mucEventChannel?.setStreamHandler(mucEventStreamHandler)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect":
            handleConnect(call: call, result: result)
        case "disconnect":
            handleDisconnect(result: result)
        case "sendMessage":
            handleSendStanza(call: call, result: result, errorCode: "SEND_MESSAGE_ERROR")
        case "sendPresence":
            handleSendStanza(call: call, result: result, errorCode: "SEND_PRESENCE_ERROR")
        case "sendIq":
            handleSendStanza(call: call, result: result, errorCode: "SEND_IQ_ERROR")
        case "getConnectionState":
            handleGetConnectionState(result: result)
        // MUC methods
        case "joinMucRoom":
            handleJoinMucRoom(call: call, result: result, errorCode: "JOIN_MUC_ERROR")
        case "leaveMucRoom":
            handleLeaveMucRoom(call: call, result: result)
        case "createMucRoom":
            handleJoinMucRoom(call: call, result: result, errorCode: "CREATE_MUC_ERROR")
        case "sendMucMessage":
            handleSendStanza(call: call, result: result, errorCode: "SEND_MUC_MESSAGE_ERROR")
        case "sendMucPrivateMessage":
            handleSendStanza(call: call, result: result, errorCode: "SEND_MUC_PRIVATE_MESSAGE_ERROR")
        case "changeMucSubject":
            handleChangeMucSubject(call: call, result: result)
        case "kickMucParticipant":
            handleMucRoleChange(call: call, result: result, role: "none")
        case "banMucUser":
            handleMucAffiliationChange(call: call, result: result, affiliation: "outcast")
        case "grantMucVoice":
            handleMucRoleChange(call: call, result: result, role: "participant")
        case "revokeMucVoice":
            handleMucRoleChange(call: call, result: result, role: "visitor")
        case "grantMucModerator":
            handleMucRoleChange(call: call, result: result, role: "moderator")
        case "grantMucMembership":
            handleMucAffiliationChange(call: call, result: result, affiliation: "member")
        case "grantMucAdmin":
            handleMucAffiliationChange(call: call, result: result, affiliation: "admin")
        case "inviteMucUser":
            handleInviteMucUser(call: call, result: result)
        case "destroyMucRoom":
            handleDestroyMucRoom(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func handleConnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }
        
        let host = args["host"] as? String ?? ""
        let port = args["port"] as? Int ?? 5222
        let username = args["username"] as? String ?? ""
        let password = args["password"] as? String ?? ""
        let domain = args["domain"] as? String ?? ""
        let useSSL = args["useSSL"] as? Bool ?? true
        let resource = args["resource"] as? String ?? "fxmpp"
        
        self.password = password
        self.allowSelfSignedCertificates = args["allowSelfSignedCertificates"] as? Bool ?? false
        
        // Retire the previous stream unconditionally — see `teardownXMPPStream`.
        teardownXMPPStream()

        let stream = setupXMPPStream()
        
        stream.hostName = host
        stream.hostPort = UInt16(port)
        
        guard let jid = XMPPJID(string: "\(username)@\(domain)/\(resource)") else {
            result(FlutterError(code: "INVALID_JID", message: "Invalid JID format", details: nil))
            return
        }
        
        stream.myJID = jid
        
        // Configure SSL/TLS
        if useSSL {
            stream.startTLSPolicy = .required
        } else {
            stream.startTLSPolicy = .allowed
        }
        
        do {
            connectionStateStreamHandler?.sendConnectionState(1) // connecting
            try stream.connect(withTimeout: 30.0) // 30 second timeout
            // `connect(withTimeout:)` only starts the asynchronous socket
            // connect; the outcome arrives through the stream delegate.
            pendingConnectResult = result
        } catch let error {
            debugPrint("Connection error: \(error.localizedDescription)")
            connectionStateStreamHandler?.sendConnectionState(4) // error
            result(FlutterError(code: "CONNECTION_ERROR", message: error.localizedDescription, details: nil))
        }
    }
    
    /// Settles the `connect` call that is waiting for this stream, if any.
    private func settlePendingConnect(_ error: FlutterError?) {
        guard let pending = pendingConnectResult else { return }
        pendingConnectResult = nil
        pending(error ?? true)
    }
    
    private func handleDisconnect(result: @escaping FlutterResult) {
        teardownXMPPStream()
        connectionStateStreamHandler?.sendConnectionState(0) // disconnected
        result(nil)
    }
    
    /// Sends a Dart-built stanza verbatim. Fails like Android does when there
    /// is no authenticated session: `XMPPStream.send` would silently drop the
    /// element while the caller was told it was sent.
    private func handleSendStanza(call: FlutterMethodCall, result: @escaping FlutterResult, errorCode: String) {
        guard let args = call.arguments as? [String: Any],
              let xmlString = args["xml"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing XML content", details: nil))
            return
        }
        
        guard let stream = xmppStream, isConnected else {
            result(FlutterError(code: errorCode, message: "XMPP connection is not connected", details: nil))
            return
        }
        
        do {
            let xmlElement = try XMPPXMLElement(xmlString: xmlString)
            stream.send(xmlElement)
            result(true)
        } catch {
            result(FlutterError(code: "XML_PARSE_ERROR", message: "Failed to parse XML: \(error.localizedDescription)", details: nil))
        }
    }
    
    private func handleGetConnectionState(result: @escaping FlutterResult) {
        if isConnected {
            result(2) // connected
        } else if xmppStream?.isConnecting == true {
            result(1) // connecting
        } else {
            result(0) // disconnected
        }
    }
    
    private func setupXMPPStream() -> XMPPStream {
        let stream = XMPPStream()
        stream.addDelegate(self, delegateQueue: DispatchQueue.main)
        
        // Background sockets are an iOS-only (and deprecated) API, absent on macOS.
        #if os(iOS)
        stream.enableBackgroundingOnSocket = true
        #endif
        
        // No XMPPRoster: the plugin exposes no roster API, and the module would
        // fetch the whole roster into a Core Data store on every login.

        // No XMPPReconnect here on purpose: reconnection is the Dart caller's
        // job. A native reconnector redialing the same account behind Dart's
        // back races the caller's own `connect`, and both sessions share one
        // resource, so the server evicts whichever is older — an endless
        // kick-each-other loop.

        // Setup MUC
        let muc = XMPPMUC()
        muc.activate(stream)
        muc.addDelegate(self, delegateQueue: DispatchQueue.main)
        xmppMUC = muc
        
        xmppStream = stream
        return stream
    }

    /// Dismantles the current stream and its modules.
    ///
    /// `handleConnect` builds a brand-new `XMPPStream` on every call, so without
    /// this the previous one stayed alive: its modules retain it, it retains them,
    /// and `self` was still its delegate — so a discarded stream kept feeding
    /// connection-state events into the single event channel and could still be
    /// logged in under the same resource as the live session.
    private func teardownXMPPStream() {
        settlePendingConnect(FlutterError(code: "CONNECTION_ERROR", message: "Connection cancelled", details: nil))
        
        for room in joinedRooms.values {
            room.removeDelegate(self)
            room.deactivate()
        }
        joinedRooms.removeAll()

        xmppMUC?.removeDelegate(self)
        xmppMUC?.deactivate()
        xmppMUC = nil

        // Drop the delegate before disconnecting so this teardown doesn't surface
        // to Dart as a spurious `disconnected`/`connectionLost` event.
        xmppStream?.removeDelegate(self)
        xmppStream?.disconnect()
        xmppStream = nil

        isConnected = false
    }

    /// Whether a delegate callback came from the live stream. `teardownXMPPStream`
    /// makes stale streams the exception rather than the rule, but a socket
    /// already closing when it runs can still call back afterwards — those events
    /// must not touch `isConnected` or reach Dart.
    private func isCurrent(_ stream: XMPPStream) -> Bool {
        return stream === xmppStream
    }

    // MARK: - MUC Method Handlers
    //
    // Everything XMPPFramework does here (`send`, `join`, `leave`, `inviteUser`)
    // is already asynchronous on its own queues, so the handlers run inline on
    // the platform thread; that also keeps `joinedRooms` single-threaded.
    
    /// The joined room for [roomJid], or reports ROOM_NOT_FOUND and returns nil.
    private func joinedRoom(_ roomJid: String, result: @escaping FlutterResult) -> XMPPRoom? {
        guard let room = joinedRooms[roomJid] else {
            result(FlutterError(code: "ROOM_NOT_FOUND", message: "Room not joined", details: nil))
            return nil
        }
        return room
    }
    
    /// `<history maxstanzas='N' since='...'/>` from the Dart join parameters.
    private func historyElement(from args: [String: Any]) -> XMPPXMLElement? {
        let maxStanzas = args["maxStanzas"] as? Int
        let since = args["since"] as? Int // millisecondsSinceEpoch
        if maxStanzas == nil && since == nil { return nil }
        let history = XMPPXMLElement(name: "history")
        if let maxStanzas = maxStanzas {
            history.addAttribute(withName: "maxstanzas", stringValue: String(maxStanzas))
        }
        if let since = since {
            let date = Date(timeIntervalSince1970: Double(since) / 1000)
            history.addAttribute(withName: "since", stringValue: ISO8601DateFormatter().string(from: date))
        }
        return history
    }
    
    /// Joins (or creates: XEP-0045 creation is joining a room that does not
    /// exist yet; `xmppRoomDidCreate` then unlocks it).
    private func handleJoinMucRoom(call: FlutterMethodCall, result: @escaping FlutterResult, errorCode: String) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String,
              let nickname = args["nickname"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
            return
        }
        
        let password = args["password"] as? String
        
        guard let stream = xmppStream, isConnected else {
            result(FlutterError(code: errorCode, message: "XMPP connection is not connected", details: nil))
            return
        }
        
        guard let roomJidObj = XMPPJID(string: roomJid) else {
            result(FlutterError(code: "INVALID_JID", message: "Invalid room JID", details: nil))
            return
        }
        
        // Re-joining replaces the previous XMPPRoom so delegates are not doubled.
        if let previous = joinedRooms[roomJid] {
            previous.removeDelegate(self)
            previous.deactivate()
        }
        
        let room = XMPPRoom(roomStorage: XMPPRoomMemoryStorage(), jid: roomJidObj, dispatchQueue: DispatchQueue.main)
        room.activate(stream)
        room.addDelegate(self, delegateQueue: DispatchQueue.main)
        room.join(usingNickname: nickname, history: historyElement(from: args), password: password)
        
        joinedRooms[roomJid] = room
        result(true)
    }
    
    private func handleLeaveMucRoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing roomJid", details: nil))
            return
        }
        
        guard let room = joinedRoom(roomJid, result: result) else { return }
        
        room.leave()
        room.removeDelegate(self)
        room.deactivate()
        joinedRooms.removeValue(forKey: roomJid)
        
        result(true)
    }
    
    private func handleChangeMucSubject(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String,
              let subject = args["subject"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
            return
        }
        
        guard let room = joinedRoom(roomJid, result: result) else { return }
        
        room.changeSubject(subject)
        result(true)
    }
    
    /// kick / grant voice / revoke voice / grant moderator: `<item nick role/>`.
    private func handleMucRoleChange(call: FlutterMethodCall, result: @escaping FlutterResult, role: String) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String,
              let nickname = args["nickname"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
            return
        }
        
        sendMucAdminIQ(roomJid: roomJid, item: ["nick": nickname, "role": role],
                       reason: args["reason"] as? String, result: result)
    }
    
    /// ban / grant membership / grant admin: `<item jid affiliation/>`.
    private func handleMucAffiliationChange(call: FlutterMethodCall, result: @escaping FlutterResult, affiliation: String) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String,
              let userJid = args["userJid"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
            return
        }
        
        guard XMPPJID(string: userJid) != nil else {
            result(FlutterError(code: "INVALID_JID", message: "Invalid user JID", details: nil))
            return
        }
        
        sendMucAdminIQ(roomJid: roomJid, item: ["jid": userJid, "affiliation": affiliation],
                       reason: args["reason"] as? String, result: result)
    }
    
    /// XMPPFramework's `editRoomPrivileges:` keys items by JID only, so the
    /// nick-addressed role changes are sent as a muc#admin IQ built here.
    private func sendMucAdminIQ(roomJid: String, item: [String: String], reason: String?, result: @escaping FlutterResult) {
        guard joinedRoom(roomJid, result: result) != nil, let stream = xmppStream else { return }
        
        let iq = XMPPIQ(type: "set", to: XMPPJID(string: roomJid))
        let query = XMPPXMLElement(name: "query", xmlns: "http://jabber.org/protocol/muc#admin")
        let itemElement = XMPPXMLElement(name: "item")
        for (name, value) in item {
            itemElement.addAttribute(withName: name, stringValue: value)
        }
        if let reason = reason {
            itemElement.addChild(XMPPXMLElement(name: "reason", stringValue: reason))
        }
        query.addChild(itemElement)
        iq.addChild(query)
        stream.send(iq)
        
        result(true)
    }
    
    private func handleInviteMucUser(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String,
              let userJid = args["userJid"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
            return
        }
        
        let reason = args["reason"] as? String ?? ""
        
        guard let room = joinedRoom(roomJid, result: result) else { return }
        
        guard let jid = XMPPJID(string: userJid) else {
            result(FlutterError(code: "INVALID_JID", message: "Invalid user JID", details: nil))
            return
        }
        
        room.inviteUser(jid, withMessage: reason)
        result(true)
    }
    
    private func handleDestroyMucRoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let roomJid = args["roomJid"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing roomJid", details: nil))
            return
        }
        
        let reason = args["reason"] as? String
        let alternativeRoom = args["alternativeRoom"] as? String
        
        guard let room = joinedRoom(roomJid, result: result), let stream = xmppStream else { return }
        
        // XMPPRoom.destroyRoom takes no alternative room or reason, so the
        // muc#owner IQ is built here.
        let iq = XMPPIQ(type: "set", to: XMPPJID(string: roomJid))
        let query = XMPPXMLElement(name: "query", xmlns: "http://jabber.org/protocol/muc#owner")
        let destroy = XMPPXMLElement(name: "destroy")
        if let altRoom = alternativeRoom {
            destroy.addAttribute(withName: "jid", stringValue: altRoom)
        }
        if let reason = reason {
            destroy.addChild(XMPPXMLElement(name: "reason", stringValue: reason))
        }
        query.addChild(destroy)
        iq.addChild(query)
        stream.send(iq)
        
        room.removeDelegate(self)
        room.deactivate()
        joinedRooms.removeValue(forKey: roomJid)
        
        result(true)
    }
}

// MARK: - XMPPStreamDelegate
extension FxmppPlugin: XMPPStreamDelegate {
    public func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        // Only reached when `willSecureWithSettings` opted into manual trust
        // evaluation, i.e. when the caller allowed self-signed certificates.
        completionHandler(allowSelfSignedCertificates)
    }
    
    public func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        // Default: GCDAsyncSocket validates the certificate chain and host name
        // itself. Manual evaluation (accept anything) only on explicit opt-in,
        // matching Android's AcceptAllTrustManager.
        if allowSelfSignedCertificates {
            settings.setValue(true, forKey: GCDAsyncSocketManuallyEvaluateTrust)
        }
    }
    
    public func xmppStreamDidConnect(_ sender: XMPPStream) {
        guard isCurrent(sender) else { return }
        do {
            try sender.authenticate(withPassword: password ?? "")
        } catch let error {
            debugPrint("Authentication error: \(error.localizedDescription)")
            connectionStateStreamHandler?.sendConnectionState(4) // error
            settlePendingConnect(FlutterError(code: "CONNECTION_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    public func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard isCurrent(sender) else { return }
        isConnected = true
        connectionStateStreamHandler?.sendConnectionState(2) // connected

        // Send initial presence
        let presence = XMPPPresence()
        sender.send(presence)
        
        settlePendingConnect(nil)
    }

    public func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: XMPPXMLElement) {
        guard isCurrent(sender) else { return }
        debugPrint("XMPP stream authentication failed: \(error)")
        connectionStateStreamHandler?.sendConnectionState(5) // authentication failed
        settlePendingConnect(FlutterError(code: "AUTH_FAILED", message: error.xmlString, details: nil))
    }

    public func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard isCurrent(sender) else { return }
        debugPrint("XMPP stream disconnected with error: \(error?.localizedDescription ?? "No error")")
        isConnected = false
        if pendingConnectResult != nil {
            // The stream never authenticated: a failed connect (unreachable host,
            // timeout), not a lost session — `error`, as on Android.
            connectionStateStreamHandler?.sendConnectionState(4) // error
            settlePendingConnect(FlutterError(code: "CONNECTION_ERROR", message: error?.localizedDescription ?? "Connection failed", details: nil))
            return
        }
        if let error = error {
            debugPrint("Disconnect error details: \(error)")
            connectionStateStreamHandler?.sendConnectionState(6) // connection lost
        } else {
            connectionStateStreamHandler?.sendConnectionState(0) // disconnected
        }
    }
    
    public func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        guard isCurrent(sender) else { return }
        let xmlString = message.xmlString
        messageStreamHandler?.sendMessage(xmlString)
    }

    public func xmppStream(_ sender: XMPPStream, didReceive presence: XMPPPresence) {
        guard isCurrent(sender) else { return }
        let xmlString = presence.xmlString
        presenceStreamHandler?.sendPresence(xmlString)
    }
        
    // Additional XMPPFramework delegate methods for comprehensive IQ handling
    public func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: any Error) {
        debugPrint("iOS FXMPP: Failed to send IQ: \(iq.xmlString), error: \(error.localizedDescription)")
    }
    
    public func xmppStream(_ sender: XMPPStream, willSend iq: XMPPIQ) -> XMPPIQ? {
        return iq
    }
    
    public func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        guard isCurrent(sender) else { return false }
        let xmlString = iq.xmlString
        iqStreamHandler?.sendIq(xmlString)
        
        // `false`: no native code answers this IQ, so XMPPFramework replies
        // with `service-unavailable` to unanswered get/set requests (RFC 6120
        // §8.2.3) — which is what Smack does on Android. Returning `true`
        // suppressed that, so server pings went unanswered and the session
        // was killed. Dart still receives the IQ and may answer it itself.
        return false
    }
}

// MARK: - XMPPMUCDelegate
extension FxmppPlugin: XMPPMUCDelegate {
    @objc(xmppMUC:roomJID:didReceiveInvitation:)
    public func xmppMUC(_ sender: XMPPMUC, roomJID: XMPPJID, didReceiveInvitation message: XMPPMessage) {
        let event: [String: Any] = [
            "type": "room_invitation",
            "roomJid": roomJID.bare,
            "from": message.from?.full ?? "",
            "reason": message.body ?? ""
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    @objc(xmppMUC:roomJID:didReceiveInvitationDecline:)
    public func xmppMUC(_ sender: XMPPMUC, roomJID: XMPPJID, didReceiveInvitationDecline message: XMPPMessage) {
        let event: [String: Any] = [
            "type": "invitation_declined",
            "roomJid": roomJID.bare,
            "from": message.from?.full ?? "",
            "reason": message.body ?? ""
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
}

// MARK: - XMPPRoomDelegate
extension FxmppPlugin: XMPPRoomDelegate {
    public func xmppRoomDidJoin(_ sender: XMPPRoom) {
        let event: [String: Any] = [
            "type": "room_joined",
            "roomJid": sender.roomJID.bare
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    public func xmppRoomDidLeave(_ sender: XMPPRoom) {
        let event: [String: Any] = [
            "type": "room_left",
            "roomJid": sender.roomJID.bare
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    @objc(xmppRoom:didReceiveMessage:fromOccupant:)
    public func xmppRoom(_ sender: XMPPRoom, didReceive message: XMPPMessage, fromOccupant occupantJID: XMPPJID) {
        let event: [String: Any] = [
            "type": "muc_message",
            "roomJid": sender.roomJID.bare,
            "from": occupantJID.full,
            "body": message.body ?? "",
            "messageType": message.type ?? "groupchat"
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    @objc(xmppRoom:occupantDidJoin:withPresence:)
    public func xmppRoom(_ sender: XMPPRoom, occupantDidJoin occupantJID: XMPPJID, with presence: XMPPPresence) {
        let event: [String: Any] = [
            "type": "participant_joined",
            "roomJid": sender.roomJID.bare,
            "participant": occupantJID.full
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    @objc(xmppRoom:occupantDidLeave:withPresence:)
    public func xmppRoom(_ sender: XMPPRoom, occupantDidLeave occupantJID: XMPPJID, with presence: XMPPPresence) {
        let event: [String: Any] = [
            "type": "participant_left",
            "roomJid": sender.roomJID.bare,
            "participant": occupantJID.full
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    public func xmppRoom(_ sender: XMPPRoom, occupantDidUpdate occupantJID: XMPPJID, with presence: XMPPPresence) {
        let event: [String: Any] = [
            "type": "participant_updated",
            "roomJid": sender.roomJID.bare,
            "participant": occupantJID.full,
            "presence": presence.xmlString
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    public func xmppRoomDidCreate(_ sender: XMPPRoom) {
        // A freshly created room is locked until its owner configures it
        // (XEP-0045 §10.1.1). Request the instant (default) configuration so
        // other users can join, as Android does with makeInstant().
        sender.configureRoom(usingOptions: nil)
        
        let event: [String: Any] = [
            "type": "room_created",
            "roomJid": sender.roomJID.bare
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    public func xmppRoomDidDestroy(_ sender: XMPPRoom) {
        let event: [String: Any] = [
            "type": "room_destroyed",
            "roomJid": sender.roomJID.bare
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
    
    @objc(xmppRoomDidChangeSubject:)
    public func xmppRoomDidChangeSubject(_ sender: XMPPRoom) {
        let event: [String: Any] = [
            "type": "subject_changed",
            "roomJid": sender.roomJID.bare,
            "subject": sender.roomSubject ?? ""
        ]
        mucEventStreamHandler?.sendEvent(event)
    }
}

// MARK: - Stream Handlers
class ConnectionStateStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events

        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil

        return nil
    }
    
    func sendConnectionState(_ state: Int) {
        eventSink?(state)
    }
}

class MessageStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        
        return nil
    }
    
    func sendMessage(_ xmlString: String) {
        eventSink?(xmlString)
    }
}

class PresenceStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    func sendPresence(_ xmlString: String) {
        eventSink?(xmlString)
    }
}

class IqStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    func sendIq(_ xmlString: String) {
        eventSink?(xmlString)
    }
}

class MucEventStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    func sendEvent(_ event: [String: Any]) {
        eventSink?(event)
    }
}
