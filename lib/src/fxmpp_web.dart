import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:fxmpp/src/core/stanza_id.dart';
import 'package:fxmpp/src/core/xmpp_connection_config.dart';
import 'package:fxmpp/src/core/xmpp_connection_state.dart';
import 'package:xml/xml.dart';

import 'fxmpp_platform_interface.dart';
import 'web/xmpp_stream_handler.dart';
import 'web/xmpp_websocket.dart';

/// Web implementation of [FxmppPlatform] using XMPP-over-WebSocket (RFC 7395).
class FxmppWeb extends FxmppPlatform {
  /// Upper bound for the WebSocket open plus the whole stream negotiation.
  /// iOS uses the same 30 s for `connect(withTimeout:)`.
  static const Duration _connectTimeout = Duration(seconds: 30);

  XmppWebSocket? _webSocket;
  StreamSubscription<String>? _incomingSubscription;
  XmppConnectionState _connectionState = XmppConnectionState.disconnected;
  String? _fullJid;

  /// Nickname used per joined room (XEP-0045 requires leaving via room/nick).
  final Map<String, String> _roomNicknames = {};

  Function(XmppConnectionState)? _connectionStateCallback;
  Function(XmlDocument)? _messageCallback;
  Function(XmlDocument)? _presenceCallback;
  Function(XmlDocument)? _iqCallback;
  // MUC events arrive as regular presence/message stanzas on web.
  // ignore: unused_field
  Function(Map<String, dynamic>)? _mucEventCallback;

  /// Registers this class as the default instance of [FxmppPlatform].
  static void registerWith(Registrar registrar) {
    FxmppPlatform.instance = FxmppWeb();
  }

  void _updateState(XmppConnectionState state) {
    _connectionState = state;
    _connectionStateCallback?.call(state);
  }

  @override
  Future<void> initialize() async {
    // No-op on web — event routing is set up in connect().
  }

  @override
  Future<bool> connect(XmppConnectionConfig config) async {
    final wsUrl = config.wsUrl;
    if (wsUrl == null || wsUrl.isEmpty) {
      throw ArgumentError(
        'wsUrl is required for web platform. '
        'Provide it in XmppConnectionConfig (e.g. wss://example.com:5443/ws).',
      );
    }

    // Retire any previous session first, as the native platforms do: an
    // orphaned socket would stay bound to the same resource and its
    // subscription would keep routing (and closing) into the new session.
    _cleanup();

    try {
      _updateState(XmppConnectionState.connecting);

      // Open WebSocket
      final socket = XmppWebSocket();
      _webSocket = socket;
      await socket.connect(wsUrl).timeout(_connectTimeout);

      // Run XMPP stream negotiation (SASL auth + resource bind)
      final handler = XmppStreamHandler(socket, config);
      _fullJid = await handler.negotiate().timeout(_connectTimeout);

      // Negotiation succeeded — set up stanza routing
      _setupStanzaRouting(socket);
      _updateState(XmppConnectionState.connected);

      // Send initial presence so the server knows we're online.
      // Native libraries (Smack, XMPPFramework) do this automatically;
      // on web we must do it explicitly or the server won't route
      // incoming stanzas to this resource.
      socket.send('<presence xmlns="jabber:client"/>');

      return true;
    } on XmppStreamException catch (e) {
      _updateState(e.state);
      _cleanup();
      return false;
    } catch (e) {
      debugPrint('XMPP connect failed: $e');
      _updateState(XmppConnectionState.error);
      _cleanup();
      return false;
    }
  }

  void _setupStanzaRouting(XmppWebSocket socket) {
    _incomingSubscription = socket.incoming.listen(
      (frame) {
        try {
          final doc = XmlDocument.parse(frame);
          final root = doc.rootElement;
          final name = root.name.local;

          switch (name) {
            case 'message':
              _messageCallback?.call(doc);
              break;
            case 'presence':
              _presenceCallback?.call(doc);
              break;
            case 'iq':
              _iqCallback?.call(doc);
              break;
            case 'close':
              _handleServerClose();
              break;
          }
        } catch (e) {
          debugPrint('Error parsing incoming XMPP frame: $e');
        }
      },
      onError: (error) {
        debugPrint('WebSocket stream error: $error');
        _updateState(XmppConnectionState.connectionLost);
      },
      onDone: () {
        if (_connectionState == XmppConnectionState.connected) {
          _updateState(XmppConnectionState.connectionLost);
        }
      },
    );
  }

  void _handleServerClose() {
    _updateState(XmppConnectionState.disconnected);
    _cleanup();
  }

  @override
  Future<void> disconnect() async {
    if (_webSocket != null && _webSocket!.isOpen) {
      _updateState(XmppConnectionState.disconnecting);
      try {
        _webSocket!.send(
          '<close xmlns="urn:ietf:params:xml:ns:xmpp-framing"/>',
        );
      } catch (_) {
        // Socket may already be closing
      }
    }
    _updateState(XmppConnectionState.disconnected);
    _cleanup();
  }

  void _cleanup() {
    _incomingSubscription?.cancel();
    _incomingSubscription = null;
    _webSocket?.dispose();
    _webSocket = null;
    _fullJid = null;
    _roomNicknames.clear();
  }

  @override
  Future<bool> sendMessage(XmlDocument message) async {
    return _sendStanza(message);
  }

  @override
  Future<bool> sendPresence(XmlDocument presence) async {
    return _sendStanza(presence);
  }

  @override
  Future<bool> sendIq(XmlDocument iq) async {
    return _sendStanza(iq);
  }

  bool _sendStanza(XmlDocument stanza) {
    if (_webSocket == null || !_webSocket!.isOpen) return false;
    try {
      _webSocket!.send(stanza.toXmlString());
      return true;
    } catch (e) {
      debugPrint('Error sending stanza: $e');
      return false;
    }
  }

  @override
  Future<XmppConnectionState> getConnectionState() async {
    return _connectionState;
  }

  @override
  void setConnectionStateCallback(Function(XmppConnectionState) callback) {
    _connectionStateCallback = callback;
  }

  @override
  void setMessageCallback(Function(XmlDocument) callback) {
    _messageCallback = callback;
  }

  @override
  void setPresenceCallback(Function(XmlDocument) callback) {
    _presenceCallback = callback;
  }

  @override
  void setIqCallback(Function(XmlDocument) callback) {
    _iqCallback = callback;
  }

  @override
  void setMucEventCallback(Function(Map<String, dynamic>) callback) {
    _mucEventCallback = callback;
  }

  // ============================================================================
  // MUC (Multi-User Chat) METHODS
  //
  // On web, MUC operations are sent as raw XMPP stanzas over the WebSocket.
  // The server handles them identically to stanzas from any XMPP client.
  // Stanzas are built with XmlBuilder so caller text is always escaped.
  // ============================================================================

  @override
  Future<bool> joinMucRoom({
    required String roomJid,
    required String nickname,
    String? password,
    int? maxStanzas,
    DateTime? since,
  }) async {
    final sent = _sendStanza(_buildStanza(
      'presence',
      attributes: {'to': '$roomJid/$nickname'},
      nest: (builder) {
        builder.element('x', attributes: {
          'xmlns': 'http://jabber.org/protocol/muc',
        }, nest: () {
          if (password != null) {
            builder.element('password', nest: password);
          }
          if (maxStanzas != null || since != null) {
            builder.element('history', attributes: {
              if (maxStanzas != null) 'maxstanzas': '$maxStanzas',
              if (since != null) 'since': since.toUtc().toIso8601String(),
            });
          }
        });
      },
    ));
    if (sent) _roomNicknames[roomJid] = nickname;
    return sent;
  }

  @override
  Future<bool> leaveMucRoom({
    required String roomJid,
    String? reason,
  }) async {
    // XEP-0045 §7.14: exit by sending unavailable presence to the occupant
    // JID (room/nick) we joined with.
    final nickname = _roomNicknames.remove(roomJid);
    final sent = _sendStanza(_buildStanza(
      'presence',
      attributes: {
        'to': nickname != null ? '$roomJid/$nickname' : roomJid,
        'type': 'unavailable',
      },
      nest: (builder) {
        if (reason != null) builder.element('status', nest: reason);
      },
    ));
    return sent;
  }

  @override
  Future<bool> sendMucMessage(XmlDocument message) async {
    return _sendStanza(message);
  }

  @override
  Future<bool> sendMucPrivateMessage(XmlDocument message) async {
    return _sendStanza(message);
  }

  @override
  Future<bool> changeMucSubject({
    required String roomJid,
    required String subject,
  }) async {
    return _sendStanza(_buildStanza(
      'message',
      attributes: {'to': roomJid, 'type': 'groupchat'},
      nest: (builder) => builder.element('subject', nest: subject),
    ));
  }

  @override
  Future<bool> kickMucParticipant({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'nick': nickname, 'role': 'none'},
      reason: reason,
    );
  }

  @override
  Future<bool> banMucUser({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'jid': userJid, 'affiliation': 'outcast'},
      reason: reason,
    );
  }

  @override
  Future<bool> grantMucVoice({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'nick': nickname, 'role': 'participant'},
      reason: reason,
    );
  }

  @override
  Future<bool> revokeMucVoice({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'nick': nickname, 'role': 'visitor'},
      reason: reason,
    );
  }

  @override
  Future<bool> grantMucModerator({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'nick': nickname, 'role': 'moderator'},
      reason: reason,
    );
  }

  @override
  Future<bool> grantMucMembership({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'jid': userJid, 'affiliation': 'member'},
      reason: reason,
    );
  }

  @override
  Future<bool> grantMucAdmin({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    return _sendMucAdminIq(
      roomJid: roomJid,
      itemAttributes: {'jid': userJid, 'affiliation': 'admin'},
      reason: reason,
    );
  }

  @override
  Future<bool> inviteMucUser({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    return _sendStanza(_buildStanza(
      'message',
      attributes: {'to': roomJid},
      nest: (builder) {
        builder.element('x', attributes: {
          'xmlns': 'http://jabber.org/protocol/muc#user',
        }, nest: () {
          builder.element('invite', attributes: {'to': userJid}, nest: () {
            if (reason != null) builder.element('reason', nest: reason);
          });
        });
      },
    ));
  }

  @override
  Future<bool> destroyMucRoom({
    required String roomJid,
    String? reason,
    String? alternativeRoom,
  }) async {
    return _sendStanza(_buildStanza(
      'iq',
      attributes: {
        'to': roomJid,
        'type': 'set',
        'id': generateStanzaId('destroy'),
      },
      nest: (builder) {
        builder.element('query', attributes: {
          'xmlns': 'http://jabber.org/protocol/muc#owner',
        }, nest: () {
          builder.element('destroy', attributes: {
            if (alternativeRoom != null) 'jid': alternativeRoom,
          }, nest: () {
            if (reason != null) builder.element('reason', nest: reason);
          });
        });
      },
    ));
  }

  @override
  Future<bool> createMucRoom({
    required String roomJid,
    required String nickname,
    String? password,
  }) async {
    // Creating a room is joining a non-existent one; the service then creates
    // it locked (XEP-0045 §10.1.1) until the owner configures it. Request an
    // instant room right away so other users can join. If the room already
    // existed and we are not its owner the service just answers an error.
    final joined = await joinMucRoom(
      roomJid: roomJid,
      nickname: nickname,
      password: password,
    );
    if (!joined) return false;
    return _sendStanza(_buildStanza(
      'iq',
      attributes: {
        'to': roomJid,
        'type': 'set',
        'id': generateStanzaId('instant'),
      },
      nest: (builder) {
        builder.element('query', attributes: {
          'xmlns': 'http://jabber.org/protocol/muc#owner',
        }, nest: () {
          builder.element('x', attributes: {
            'xmlns': 'jabber:x:data',
            'type': 'submit',
          });
        });
      },
    ));
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

  /// Build a `jabber:client` stanza from this session's full JID.
  XmlDocument _buildStanza(
    String name, {
    required Map<String, String> attributes,
    required void Function(XmlBuilder builder) nest,
  }) {
    final builder = XmlBuilder();
    builder.element(name, attributes: {
      'xmlns': 'jabber:client',
      if (_fullJid != null) 'from': _fullJid!,
      ...attributes,
    }, nest: () => nest(builder));
    return builder.buildDocument();
  }

  /// Send a MUC admin IQ stanza for role/affiliation changes.
  Future<bool> _sendMucAdminIq({
    required String roomJid,
    required Map<String, String> itemAttributes,
    String? reason,
  }) async {
    return _sendStanza(_buildStanza(
      'iq',
      attributes: {
        'to': roomJid,
        'type': 'set',
        'id': generateStanzaId('muc_admin'),
      },
      nest: (builder) {
        builder.element('query', attributes: {
          'xmlns': 'http://jabber.org/protocol/muc#admin',
        }, nest: () {
          builder.element('item', attributes: itemAttributes, nest: () {
            if (reason != null) builder.element('reason', nest: reason);
          });
        });
      },
    ));
  }
}
