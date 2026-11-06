package dev.hainguyen.fxmpp

import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.jivesoftware.smack.AbstractXMPPConnection
import org.jivesoftware.smack.ConnectionConfiguration
import org.jivesoftware.smack.ConnectionListener
import org.jivesoftware.smack.SmackException
import org.jivesoftware.smack.XMPPConnection
import org.jivesoftware.smack.XMPPException
import org.jivesoftware.smack.sasl.SASLErrorException
import org.jivesoftware.smack.packet.IQ
import org.jivesoftware.smack.packet.Message
import org.jivesoftware.smack.packet.Presence
import org.jivesoftware.smack.packet.Stanza
import org.jivesoftware.smack.packet.XmlEnvironment
import org.jivesoftware.smack.tcp.XMPPTCPConnection
import org.jivesoftware.smack.tcp.XMPPTCPConnectionConfiguration
import org.jxmpp.jid.impl.JidCreate
import java.io.IOException
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager
import java.util.*
import java.util.concurrent.Executors
import org.jivesoftware.smackx.muc.MultiUserChat
import org.jivesoftware.smackx.muc.MultiUserChatManager
import org.jivesoftware.smackx.muc.MucEnterConfiguration
import org.jivesoftware.smackx.muc.ParticipantStatusListener
import org.jivesoftware.smackx.muc.SubjectUpdatedListener
import org.jivesoftware.smackx.muc.UserStatusListener
import org.jxmpp.jid.EntityBareJid
import org.jxmpp.jid.EntityFullJid
import org.jxmpp.jid.Jid
import org.jxmpp.jid.parts.Resourcepart

class FxmppPlugin: FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var connectionStateEventChannel: EventChannel
    private lateinit var messageEventChannel: EventChannel
    private lateinit var presenceEventChannel: EventChannel
    private lateinit var iqEventChannel: EventChannel
    private lateinit var mucEventChannel: EventChannel
    
    private var connectionStateStreamHandler: ConnectionStateStreamHandler? = null
    private var messageStreamHandler: MessageStreamHandler? = null
    private var presenceStreamHandler: PresenceStreamHandler? = null
    private var iqStreamHandler: IqStreamHandler? = null
    private var mucEventStreamHandler: MucEventStreamHandler? = null
    
    private var connection: AbstractXMPPConnection? = null
    private var connectionListener: ConnectionListener? = null
    private var mucManager: MultiUserChatManager? = null
    private val joinedRooms = mutableMapOf<String, MultiUserChat>()
    // MultiUserChatManager caches one MultiUserChat per room JID, so listeners
    // must be attached once per instance, not once per join.
    private val listenedRooms = mutableSetOf<MultiUserChat>()
    
    private val mainHandler = Handler(Looper.getMainLooper())
    // Outgoing stanzas go through one thread so they reach Smack's writer in
    // call order; sendStanza itself is a non-blocking queue put.
    private val sendExecutor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "fxmpp")
        channel.setMethodCallHandler(this)
        
        // Set up event channels
        connectionStateEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "fxmpp/connection_state")
        connectionStateStreamHandler = ConnectionStateStreamHandler()
        connectionStateEventChannel.setStreamHandler(connectionStateStreamHandler)
        
        messageEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "fxmpp/messages")
        messageStreamHandler = MessageStreamHandler()
        messageEventChannel.setStreamHandler(messageStreamHandler)
        
        presenceEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "fxmpp/presence")
        presenceStreamHandler = PresenceStreamHandler()
        presenceEventChannel.setStreamHandler(presenceStreamHandler)
        
        iqEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "fxmpp/iq")
        iqStreamHandler = IqStreamHandler()
        iqEventChannel.setStreamHandler(iqStreamHandler)
        
        mucEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "fxmpp/muc_events")
        mucEventStreamHandler = MucEventStreamHandler()
        mucEventChannel.setStreamHandler(mucEventStreamHandler)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "connect" -> handleConnect(call, result)
            "disconnect" -> handleDisconnect(result)
            "sendMessage" -> handleSendStanza(call, result, "SEND_MESSAGE_ERROR")
            "sendPresence" -> handleSendStanza(call, result, "SEND_PRESENCE_ERROR")
            "sendIq" -> handleSendStanza(call, result, "SEND_IQ_ERROR")
            "getConnectionState" -> handleGetConnectionState(result)
            // MUC methods
            "joinMucRoom" -> handleJoinMucRoom(call, result)
            "leaveMucRoom" -> handleLeaveMucRoom(call, result)
            "createMucRoom" -> handleCreateMucRoom(call, result)
            "sendMucMessage" -> handleSendStanza(call, result, "SEND_MUC_MESSAGE_ERROR")
            "sendMucPrivateMessage" -> handleSendStanza(call, result, "SEND_MUC_PRIVATE_MESSAGE_ERROR")
            "changeMucSubject" -> handleChangeMucSubject(call, result)
            "kickMucParticipant" -> handleKickMucParticipant(call, result)
            "banMucUser" -> handleBanMucUser(call, result)
            "grantMucVoice" -> handleGrantMucVoice(call, result)
            "revokeMucVoice" -> handleRevokeMucVoice(call, result)
            "grantMucModerator" -> handleGrantMucModerator(call, result)
            "grantMucMembership" -> handleGrantMucMembership(call, result)
            "grantMucAdmin" -> handleGrantMucAdmin(call, result)
            "inviteMucUser" -> handleInviteMucUser(call, result)
            "destroyMucRoom" -> handleDestroyMucRoom(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleConnect(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val host = args["host"] as? String ?: ""
        val port = args["port"] as? Int ?: 5222
        val username = args["username"] as? String ?: ""
        val password = args["password"] as? String ?: ""
        val domain = args["domain"] as? String ?: ""
        val useSSL = args["useSSL"] as? Boolean ?: true
        val allowSelfSignedCertificates = args["allowSelfSignedCertificates"] as? Boolean ?: false
        val resource = args["resource"] as? String ?: "fxmpp"
        
        Thread {
            try {
                // Retire the previous connection unconditionally — see
                // `teardownConnection`. Not graceful: a dead link would make
                // the closing-tag wait eat the whole reply timeout.
                teardownConnection(graceful = false)

                val configBuilder = XMPPTCPConnectionConfiguration.builder()
                    .setHost(host)
                    .setPort(port)
                    .setXmppDomain(domain)
                    .setResource(resource)
                    // Smack 4.4 renders xml:lang as Locale.toString() with
                    // '_'→'-', so locales carrying a script or extension
                    // (e.g. ar-SY-u-nu-arab → "ar-SY-#u-nu-arab") produce an
                    // invalid tag and ejabberd closes the stream with
                    // invalid-xml. Keep only language + country.
                    .setLanguage(Locale.getDefault().let { Locale(it.language, it.country) })

                if (useSSL) {
                    configBuilder.setSecurityMode(ConnectionConfiguration.SecurityMode.required)
                } else {
                    configBuilder.setSecurityMode(ConnectionConfiguration.SecurityMode.disabled)
                }
                
                if (allowSelfSignedCertificates) {
                    configBuilder.setCustomX509TrustManager(AcceptAllTrustManager())
                }
                
                val config = configBuilder.build()
                connection = FxmppTcpConnection(config)

                val listener = object : ConnectionListener {
                    override fun connected(connection: XMPPConnection) {
                        mainHandler.post {
                            connectionStateStreamHandler?.sendConnectionState(1) // connecting
                        }
                    }
                    
                    override fun authenticated(connection: XMPPConnection, resumed: Boolean) {
                        mainHandler.post {
                            connectionStateStreamHandler?.sendConnectionState(2) // connected
                        }
                        // Listen on the connection we were handed, and only
                        // once: a stream-management resumption re-enters here.
                        if (!resumed) setupListeners(connection)
                    }
                    
                    override fun connectionClosed() {
                        mainHandler.post {
                            connectionStateStreamHandler?.sendConnectionState(0) // disconnected
                        }
                    }
                    
                    override fun connectionClosedOnError(e: Exception) {
                        mainHandler.post {
                            connectionStateStreamHandler?.sendConnectionState(6) // connection lost
                        }
                    }
                }
                connectionListener = listener
                connection?.addConnectionListener(listener)

                connection?.connect()
                connection?.login(username, password)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                val authFailed = e is SASLErrorException || e is SmackException.SmackSaslException
                mainHandler.post {
                    if (authFailed) {
                        connectionStateStreamHandler?.sendConnectionState(5) // authentication failed
                        result.error("AUTH_FAILED", e.message, null)
                    } else {
                        connectionStateStreamHandler?.sendConnectionState(4) // error
                        result.error("CONNECTION_ERROR", e.message, null)
                    }
                }
            }
        }.start()
    }
    
    /**
     * Disconnects and releases the current connection.
     *
     * `handleConnect` builds a brand-new `XMPPTCPConnection` on every call, so
     * without this the previous one stayed alive and logged in — still holding
     * its listeners, still feeding connection-state events into the single event
     * channel, and still occupying the same resource as the new session, which
     * makes the server evict whichever of the two is older.
     *
     * Blocks on socket close, so callers must already be off the main thread.
     *
     * [graceful] sends `</stream:stream>` and waits (up to the reply timeout)
     * for the server's closing tag; otherwise the socket is closed at once.
     */
    private fun teardownConnection(graceful: Boolean) {
        val previous = connection ?: return
        // Detach first, so this teardown doesn't surface to Dart as a spurious
        // `disconnected` event mid-reconnect.
        connectionListener?.let { previous.removeConnectionListener(it) }
        connectionListener = null
        connection = null
        mucManager = null
        joinedRooms.clear()
        listenedRooms.clear()
        try {
            if (graceful || previous !is XMPPTCPConnection) {
                previous.disconnect()
            } else {
                previous.instantShutdown()
            }
        } catch (e: Exception) {
            // Best effort: closing an already-broken socket can throw.
        }
    }

    private fun handleDisconnect(result: Result) {
        Thread {
            try {
                teardownConnection(graceful = true)
                mainHandler.post {
                    connectionStateStreamHandler?.sendConnectionState(0) // disconnected
                    result.success(null)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("DISCONNECT_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    /**
     * Writes a Dart-built stanza to the stream verbatim.
     *
     * Dart serializes a complete, well-formed stanza, so there is nothing to
     * gain from re-parsing it into Smack's object model — and plenty to lose:
     * payloads without an IQProvider were XML-escaped into text (1.0.4), and
     * extensions with mixed content are reordered by StandardExtensionElement.
     * [RawStanza] keeps the bytes as they are while still being a Stanza, so
     * XEP-0198 stream management keeps counting it (a Nonza is not counted and
     * desynchronises the ack counters, which Smack treats as a stream error).
     */
    private fun handleSendStanza(call: MethodCall, result: Result, errorCode: String) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val xmlString = args["xml"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing XML content", null)
            return
        }
        
        val conn = connection
        if (conn == null || !conn.isConnected) {
            result.error(errorCode, "XMPP connection is not connected", null)
            return
        }
        
        sendExecutor.execute {
            try {
                (conn as FxmppTcpConnection).sendRawStanza(RawStanza(xmlString))
                mainHandler.post {
                    result.success(true)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(errorCode, e.message, null)
                }
            }
        }
    }
    
    private fun handleGetConnectionState(result: Result) {
        val state = when {
            connection?.isConnected == true && connection?.isAuthenticated == true -> 2 // connected
            connection?.isConnected == true -> 1 // connecting
            else -> 0 // disconnected
        }
        result.success(state)
    }
    
    private fun setupListeners(conn: XMPPConnection) {
        // One listener for every stanza. Every <message> is forwarded, as on
        // iOS/macOS and Web: Smack's ChatManager only delivered chat/normal
        // messages with a <body> from a full JID, which silently dropped MUC
        // groupchat traffic, error bounces, headlines, server notices and
        // archive pages. Dart filters what it needs.
        //
        // Sync, not async: Smack runs async listeners on a thread pool with no
        // ordering between stanzas, so a MAM page's closing IQ <fin> could
        // reach Dart before its <result> messages and those records were lost.
        // Sync listeners run in arrival order on one thread; the body only
        // serializes and posts to the (FIFO) main looper, so it never blocks.
        conn.addSyncStanzaListener({ stanza ->
            val xmlString = stanza.toXML().toString()
            when (stanza) {
                is Message -> {
                    val messageMap = mapOf(
                        "from" to (stanza.from?.toString() ?: ""),
                        "xml" to xmlString
                    )
                    mainHandler.post {
                        messageStreamHandler?.sendMessage(messageMap)
                    }
                }
                is Presence -> mainHandler.post {
                    presenceStreamHandler?.sendPresence(xmlString)
                }
                is IQ -> mainHandler.post {
                    iqStreamHandler?.sendIq(xmlString)
                }
            }
        }, null)
        
        // Set up MUC manager
        mucManager = MultiUserChatManager.getInstanceFor(conn)
    }

    // ============================================================================
    // MUC (Multi-User Chat) METHOD HANDLERS
    // ============================================================================

    private fun handleJoinMucRoom(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val password = args["password"] as? String
        val maxStanzas = args["maxStanzas"] as? Int
        val since = args["since"] as? Long
        
        Thread {
            try {
                val entityBareJid = JidCreate.entityBareFrom(roomJid)
                val resourcepart = Resourcepart.from(nickname)
                val muc = mucManager?.getMultiUserChat(entityBareJid)
                
                if (muc == null) {
                    throw Exception("Failed to get MultiUserChat instance")
                }
                
                // Set up listeners for this room (once per cached instance)
                if (listenedRooms.add(muc)) setupMucListeners(muc, roomJid)
                
                // Configure join parameters
                val enterConfigBuilder = muc.getEnterConfigurationBuilder(resourcepart)
                
                if (password != null) {
                    enterConfigBuilder.withPassword(password)
                }
                
                if (maxStanzas != null) {
                    enterConfigBuilder.requestMaxStanzasHistory(maxStanzas)
                }
                
                if (since != null) {
                    enterConfigBuilder.requestHistorySince(Date(since))
                }
                
                val enterConfig = enterConfigBuilder.build()
                muc.join(enterConfig)
                
                // Store the joined room
                joinedRooms[roomJid] = muc
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("JOIN_MUC_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleLeaveMucRoom(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                muc.leave()
                
                joinedRooms.remove(roomJid)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("LEAVE_MUC_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleCreateMucRoom(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val password = args["password"] as? String
        
        Thread {
            try {
                val entityBareJid = JidCreate.entityBareFrom(roomJid)
                val resourcepart = Resourcepart.from(nickname)
                val muc = mucManager?.getMultiUserChat(entityBareJid)
                
                if (muc == null) {
                    throw Exception("Failed to get MultiUserChat instance")
                }
                
                // Set up listeners for this room (once per cached instance)
                if (listenedRooms.add(muc)) setupMucListeners(muc, roomJid)
                
                // Create and join the room
                val enterConfigBuilder = muc.getEnterConfigurationBuilder(resourcepart)
                if (password != null) {
                    enterConfigBuilder.withPassword(password)
                }
                
                val enterConfig = enterConfigBuilder.build()
                // A newly created room is locked until its owner configures it
                // (XEP-0045 §10.1.1); request an instant room so others can
                // join. createOrJoin returns null when the room already existed.
                muc.createOrJoin(enterConfig)?.makeInstant()
                
                // Store the joined room
                joinedRooms[roomJid] = muc
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("CREATE_MUC_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleChangeMucSubject(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val subject = args["subject"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing subject", null)
            return
        }
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                muc.changeSubject(subject)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("CHANGE_MUC_SUBJECT_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleKickMucParticipant(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val resourcepart = Resourcepart.from(nickname)
                if (reason != null) {
                    muc.kickParticipant(resourcepart, reason)
                } else {
                    muc.kickParticipant(resourcepart, "")
                }
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("KICK_MUC_PARTICIPANT_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleBanMucUser(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val userJid = args["userJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing userJid", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val jid = JidCreate.from(userJid)
                if (reason != null) {
                    muc.banUser(jid, reason)
                } else {
                    muc.banUser(jid, "")
                }
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("BAN_MUC_USER_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleGrantMucVoice(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val resourcepart = Resourcepart.from(nickname)
                muc.grantVoice(resourcepart)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("GRANT_MUC_VOICE_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleRevokeMucVoice(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val resourcepart = Resourcepart.from(nickname)
                muc.revokeVoice(resourcepart)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("REVOKE_MUC_VOICE_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleGrantMucModerator(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val nickname = args["nickname"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing nickname", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val resourcepart = Resourcepart.from(nickname)
                muc.grantModerator(resourcepart)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("GRANT_MUC_MODERATOR_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleGrantMucMembership(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val userJid = args["userJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing userJid", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val jid = JidCreate.from(userJid)
                muc.grantMembership(jid)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("GRANT_MUC_MEMBERSHIP_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleGrantMucAdmin(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val userJid = args["userJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing userJid", null)
            return
        }
        
        val reason = args["reason"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val jid = JidCreate.from(userJid)
                muc.grantAdmin(jid)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("GRANT_MUC_ADMIN_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleInviteMucUser(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val userJid = args["userJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing userJid", null)
            return
        }
        
        val reason = args["reason"] as? String ?: ""
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val entityBareJid = JidCreate.entityBareFrom(userJid)
                muc.invite(entityBareJid, reason)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("INVITE_MUC_USER_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun handleDestroyMucRoom(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any> ?: run {
            result.error("INVALID_ARGUMENTS", "Invalid arguments", null)
            return
        }
        
        val roomJid = args["roomJid"] as? String ?: run {
            result.error("INVALID_ARGUMENTS", "Missing roomJid", null)
            return
        }
        
        val reason = args["reason"] as? String
        val alternativeRoom = args["alternativeRoom"] as? String
        
        Thread {
            try {
                val muc = joinedRooms[roomJid] ?: run {
                    throw Exception("Not joined to room $roomJid")
                }
                
                val alternativeJid = if (alternativeRoom != null) {
                    JidCreate.entityBareFrom(alternativeRoom)
                } else null
                
                muc.destroy(reason ?: "", alternativeJid)
                joinedRooms.remove(roomJid)
                
                mainHandler.post {
                    result.success(true)
                }
                
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("DESTROY_MUC_ROOM_ERROR", e.message, null)
                }
            }
        }.start()
    }
    
    private fun setupMucListeners(muc: MultiUserChat, roomJid: String) {
        // Set up participant status listener
        muc.addParticipantStatusListener(object : ParticipantStatusListener {
            override fun joined(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "participant_joined",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun left(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "participant_left",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun kicked(participant: EntityFullJid, actor: Jid?, reason: String?) {
                val event = mapOf(
                    "type" to "participant_kicked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString(),
                    "actor" to (actor?.toString() ?: ""),
                    "reason" to (reason ?: "")
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun banned(participant: EntityFullJid, actor: Jid?, reason: String?) {
                val event = mapOf(
                    "type" to "participant_banned",
                    "roomJid" to roomJid,
                    "participant" to participant.toString(),
                    "actor" to (actor?.toString() ?: ""),
                    "reason" to (reason ?: "")
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun membershipGranted(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "membership_granted",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun membershipRevoked(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "membership_revoked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun moderatorGranted(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "moderator_granted",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun moderatorRevoked(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "moderator_revoked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun ownershipGranted(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "ownership_granted",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun ownershipRevoked(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "ownership_revoked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun adminGranted(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "admin_granted",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun adminRevoked(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "admin_revoked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun voiceGranted(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "voice_granted",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun voiceRevoked(participant: EntityFullJid) {
                val event = mapOf(
                    "type" to "voice_revoked",
                    "roomJid" to roomJid,
                    "participant" to participant.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun nicknameChanged(participant: EntityFullJid, newNickname: Resourcepart) {
                val event = mapOf(
                    "type" to "nickname_changed",
                    "roomJid" to roomJid,
                    "participant" to participant.toString(),
                    "newNickname" to newNickname.toString()
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
        })
        
        // Set up subject updated listener
        muc.addSubjectUpdatedListener { subject, from ->
            val event = mapOf(
                "type" to "subject_updated",
                "roomJid" to roomJid,
                "subject" to subject,
                "from" to from.toString()
            )
            mainHandler.post {
                mucEventStreamHandler?.sendEvent(event)
            }
        }
        
        // Set up user status listener
        muc.addUserStatusListener(object : UserStatusListener {
            override fun kicked(actor: Jid?, reason: String?) {
                val event = mapOf(
                    "type" to "user_kicked",
                    "roomJid" to roomJid,
                    "actor" to (actor?.toString() ?: ""),
                    "reason" to (reason ?: "")
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun banned(actor: Jid?, reason: String?) {
                val event = mapOf(
                    "type" to "user_banned",
                    "roomJid" to roomJid,
                    "actor" to (actor?.toString() ?: ""),
                    "reason" to (reason ?: "")
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
            
            override fun roomDestroyed(alternateMUC: MultiUserChat?, reason: String?) {
                val event = mapOf(
                    "type" to "room_destroyed",
                    "roomJid" to roomJid,
                    "alternateRoom" to (alternateMUC?.room?.toString() ?: ""),
                    "reason" to (reason ?: "")
                )
                mainHandler.post {
                    mucEventStreamHandler?.sendEvent(event)
                }
            }
        })
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        connectionStateEventChannel.setStreamHandler(null)
        messageEventChannel.setStreamHandler(null)
        presenceEventChannel.setStreamHandler(null)
        iqEventChannel.setStreamHandler(null)
        mucEventChannel.setStreamHandler(null)
        
        // Disconnect off the main thread: a graceful close waits for the
        // server (reply timeout) and closes an SSL socket. The server drops
        // our room occupancy with the session, so rooms need no explicit leave.
        Thread { teardownConnection(graceful = true) }.start()
        sendExecutor.shutdown()
    }
}

// Stream Handlers
class ConnectionStateStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    fun sendConnectionState(state: Int) {
        eventSink?.success(state)
    }
}

class MessageStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    fun sendMessage(message: Map<String, Any>) {
        eventSink?.success(message)
    }
}

class PresenceStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    fun sendPresence(xmlString: String) {
        eventSink?.success(xmlString)
    }
}

class IqStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    fun sendIq(xmlString: String) {
        eventSink?.success(xmlString)
    }
}

class MucEventStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }
    
    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    fun sendEvent(event: Map<String, Any>) {
        eventSink?.success(event)
    }
}

/// A stanza Smack writes to the stream byte for byte.
///
/// Smack can only re-serialize what it has a provider for; anything else is
/// mangled on the way out (see [FxmppPlugin.handleSendStanza]). Unlike a Nonza,
/// a Stanza is tracked by XEP-0198 stream management, so the server's ack
/// counters stay in step with Smack's. Send it with
/// [FxmppTcpConnection.sendRawStanza], never sendStanza (see there).
class RawStanza(private val xml: String) : Stanza() {
    /// Root element name (message / presence / iq), read from the XML itself.
    private val elementName: String =
        Regex("^\\s*<([^\\s/>]+)").find(xml)?.groupValues?.get(1)?.substringAfter(':') ?: "message"

    override fun getElementName(): String = elementName
    override fun toXML(enclosingNamespace: XmlEnvironment?): CharSequence = xml
    override fun toString(): String = xml
}

/// AbstractXMPPConnection.sendStanza asserts the stanza is a Message/Presence/IQ.
/// D8 keeps Java asserts live in debuggable builds, so sending a [RawStanza]
/// through it throws AssertionError (an Error, not an Exception) and kills the
/// app. This mirrors sendStanza minus that assert; the skipped interceptors
/// only ever match Message/Presence instances, so they never saw a RawStanza.
class FxmppTcpConnection(config: XMPPTCPConnectionConfiguration) : XMPPTCPConnection(config) {
    fun sendRawStanza(stanza: RawStanza) {
        throwNotConnectedExceptionIfAppropriate()
        sendStanzaInternal(stanza)
    }
}

// Trust manager for self-signed certificates
class AcceptAllTrustManager : javax.net.ssl.X509TrustManager {
    override fun checkClientTrusted(chain: Array<java.security.cert.X509Certificate>, authType: String) {}
    override fun checkServerTrusted(chain: Array<java.security.cert.X509Certificate>, authType: String) {}
    override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = arrayOf()
}
