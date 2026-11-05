import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fxmpp/src/core/iq_type.dart';
import 'package:fxmpp/src/core/message_type.dart';
import 'package:fxmpp/src/core/muc_room.dart';
import 'package:fxmpp/src/core/presence_type.dart';
import 'package:fxmpp/src/core/stanza_id.dart';
import 'package:fxmpp/src/core/xmpp_connection_config.dart';
import 'package:fxmpp/src/core/xmpp_connection_state.dart';
import 'package:xml/xml.dart';
import 'fxmpp_platform_interface.dart';

import 'muc_manager.dart';

/// Main FXMPP class for XMPP operations
class Fxmpp {
  static final Fxmpp _instance = Fxmpp._internal();
  factory Fxmpp() => _instance;
  Fxmpp._internal();

  /// Stream controller for connection state changes
  final StreamController<XmppConnectionState> _connectionStateController =
      StreamController<XmppConnectionState>.broadcast();

  /// Stream controller for incoming messages
  final StreamController<XmlDocument> _messageController =
      StreamController<XmlDocument>.broadcast();

  /// Stream controller for presence updates
  final StreamController<XmlDocument> _presenceController =
      StreamController<XmlDocument>.broadcast();

  /// Stream controller for IQ stanzas
  final StreamController<XmlDocument> _iqController =
      StreamController<XmlDocument>.broadcast();

  /// MUC manager instance
  final MucManager _mucManager = MucManager();

  /// Stream of connection state changes
  Stream<XmppConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Stream of incoming messages
  Stream<XmlDocument> get messageStream => _messageController.stream;

  /// Stream of presence updates
  Stream<XmlDocument> get presenceStream => _presenceController.stream;

  /// Stream of IQ stanzas
  Stream<XmlDocument> get iqStream => _iqController.stream;

  /// Stream of MUC room events
  Stream<MucRoomEvent> get mucRoomEventStream => _mucManager.roomEventStream;

  /// Stream of MUC participant events
  Stream<MucParticipantEvent> get mucParticipantEventStream =>
      _mucManager.participantEventStream;

  /// Stream of MUC messages
  Stream<MucMessage> get mucMessageStream => _mucManager.mucMessageStream;

  /// Get MUC manager instance
  MucManager get mucManager => _mucManager;

  /// Connect to XMPP server.
  ///
  /// Resolves `true` once the session is authenticated and `false` when the
  /// connection or authentication failed; the reason (`error` or
  /// `authenticationFailed`) is reported on [connectionStateStream] by the
  /// platform itself, on every platform.
  Future<bool> connect(XmppConnectionConfig config) async {
    if (kDebugMode) log("[XMPP-Connection] connect ${config.toString()}");
    try {
      return await FxmppPlatform.instance.connect(config);
    } on PlatformException catch (e) {
      if (kDebugMode) {
        if (kDebugMode) log("[XMPP-Connection] connect failed: ${e.code} ${e.message}");
      }
      return false;
    }
  }

  /// Disconnect from XMPP server.
  ///
  /// The platform emits `disconnected` on [connectionStateStream].
  Future<void> disconnect() async {
    await FxmppPlatform.instance.disconnect();
    if (kDebugMode) log("[XMPP-Connection] << disconnect");
  }

  /// Send a message
  Future<bool> sendMessage(XmlDocument message) async {
    if (kDebugMode) log("[XMPP-Message] >>> ${message.toXmlString()}");
    return await FxmppPlatform.instance.sendMessage(message);
  }

  /// Send presence
  Future<bool> sendPresence(XmlDocument presence) async {
    if (kDebugMode) log("[XMPP-Presence] >>> ${presence.toXmlString()}");
    return await FxmppPlatform.instance.sendPresence(presence);
  }

  /// Send IQ stanza
  Future<bool> sendIq(XmlDocument iq) async {
    if (kDebugMode) log("[XMPP-IQ] >>> ${iq.toXmlString()}");
    return await FxmppPlatform.instance.sendIq(iq);
  }

  /// Get current connection state
  Future<XmppConnectionState> getConnectionState() async {
    return await FxmppPlatform.instance.getConnectionState();
  }

  /// Initialize the plugin and set up listeners
  Future<void> initialize() async {
    await FxmppPlatform.instance.initialize();

    // Set up platform callbacks. Guard against a disposed singleton: the
    // platform keeps calling back after dispose() and a closed controller
    // throws on add().
    FxmppPlatform.instance.setConnectionStateCallback((state) {
      if (kDebugMode) log("[XMPP-Connection] didChangeConnectionState $state");
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(state);
      }
    });

    FxmppPlatform.instance.setMessageCallback((message) {
      if (kDebugMode) log("[XMPP-Message] <<< ${message.toXmlString()}");
      if (!_messageController.isClosed) _messageController.add(message);
      // Room messages update MucManager state (subject) and mucMessageStream.
      _mucManager.handleMessage(message);
    });

    FxmppPlatform.instance.setPresenceCallback((presence) {
      if (kDebugMode) log("[XMPP-Presence] <<< ${presence.toXmlString()}");
      if (!_presenceController.isClosed) _presenceController.add(presence);
      // MUC occupant presence drives joined/participant state on every
      // platform (the native MUC event channel is a platform-specific extra).
      _mucManager.handlePresence(presence);
    });

    FxmppPlatform.instance.setIqCallback((iq) {
      if (kDebugMode) log("[XMPP-IQ] <<< ${iq.toXmlString()}");
      if (!_iqController.isClosed) _iqController.add(iq);
    });

    // Native MUC lifecycle events (Android/iOS only). Room state itself is
    // derived from presence above, so these are only logged.
    FxmppPlatform.instance.setMucEventCallback((event) {
      if (kDebugMode) log("[XMPP-MUC] Event: $event");
    });
  }

  /// Dispose resources
  void dispose() {
    _connectionStateController.close();
    _messageController.close();
    _presenceController.close();
    _iqController.close();
    _mucManager.dispose();
  }

  // ============================================================================
  // UTILITY METHODS FOR CREATING BASIC STANZAS
  // ============================================================================

  /// Create a basic message stanza
  ///
  /// [messageId] - Unique identifier for the message
  /// [type] - Type of message (chat, groupchat, normal, etc.)
  /// [fromJid] - Sender's JID
  /// [toJid] - Recipient's JID
  /// [content] - Message content/body
  /// [subject] - Optional message subject
  /// [thread] - Optional thread identifier for conversation tracking
  static XmlDocument createMessage({
    required String messageId,
    required MessageType type,
    required String fromJid,
    required String toJid,
    required String content,
    String? subject,
    String? thread,
  }) {
    final builder = XmlBuilder();
    builder.element('message', attributes: {
      'xmlns': 'jabber:client',
      'id': messageId,
      'type': type.value,
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      if (subject != null && subject.isNotEmpty) {
        builder.element('subject', nest: subject);
      }
      builder.element('body', nest: content);
      if (thread != null && thread.isNotEmpty) {
        builder.element('thread', nest: thread);
      }
    });
    return builder.buildDocument();
  }

  /// Create a basic presence stanza
  ///
  /// [presenceId] - Optional unique identifier for the presence
  /// [type] - Type of presence (available, unavailable, subscribe, etc.)
  /// [fromJid] - Sender's JID
  /// [toJid] - Optional recipient's JID (for directed presence)
  /// [show] - Availability status (away, dnd, chat, etc.)
  /// [status] - Human-readable status message
  /// [priority] - Presence priority (-128 to 127)
  static XmlDocument createPresence({
    String? presenceId,
    PresenceType type = PresenceType.available,
    required String fromJid,
    String? toJid,
    PresenceShow show = PresenceShow.available,
    String? status,
    int? priority,
  }) {
    final builder = XmlBuilder();
    final attributes = <String, String>{
      'xmlns': 'jabber:client',
      'from': fromJid,
    };

    if (presenceId != null) {
      attributes['id'] = presenceId;
    }

    if (type.value != null) {
      attributes['type'] = type.value!;
    }

    if (toJid != null) {
      attributes['to'] = toJid;
    }

    builder.element('presence', attributes: attributes, nest: () {
      if (show.value != null) {
        builder.element('show', nest: show.value!);
      }
      if (status != null && status.isNotEmpty) {
        builder.element('status', nest: status);
      }
      if (priority != null) {
        builder.element('priority', nest: priority.toString());
      }
    });
    return builder.buildDocument();
  }

  /// Create a basic IQ stanza
  ///
  /// [iqId] - Unique identifier for the IQ
  /// [type] - Type of IQ (get, set, result, error)
  /// [fromJid] - Sender's JID
  /// [toJid] - Recipient's JID
  /// [queryElement] - Optional query element for the IQ payload
  static XmlDocument createIq({
    required String iqId,
    required IqType type,
    required String fromJid,
    required String toJid,
    XmlElement? queryElement,
  }) {
    final builder = XmlBuilder();
    builder.element('iq', attributes: {
      'xmlns': 'jabber:client',
      'id': iqId,
      'type': type.value,
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      if (queryElement != null) {
        // Insert a verbatim copy (prefixes, namespaces and CDATA included).
        builder.xml(queryElement.toXmlString());
      }
    });
    return builder.buildDocument();
  }

  /// Create a disco#info IQ query
  ///
  /// [iqId] - Unique identifier for the IQ
  /// [fromJid] - Sender's JID
  /// [toJid] - Target JID to query
  /// [node] - Optional node to query
  static XmlDocument createDiscoInfoQuery({
    required String iqId,
    required String fromJid,
    required String toJid,
    String? node,
  }) {
    final builder = XmlBuilder();
    builder.element('iq', attributes: {
      'xmlns': 'jabber:client',
      'id': iqId,
      'type': 'get',
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      final queryAttrs = <String, String>{
        'xmlns': 'http://jabber.org/protocol/disco#info',
      };
      if (node != null) {
        queryAttrs['node'] = node;
      }
      builder.element('query', attributes: queryAttrs);
    });
    return builder.buildDocument();
  }

  /// Create a version IQ query
  ///
  /// [iqId] - Unique identifier for the IQ
  /// [fromJid] - Sender's JID
  /// [toJid] - Target JID to query
  static XmlDocument createVersionQuery({
    required String iqId,
    required String fromJid,
    required String toJid,
  }) {
    final builder = XmlBuilder();
    builder.element('iq', attributes: {
      'xmlns': 'jabber:client',
      'id': iqId,
      'type': 'get',
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      builder.element('query', attributes: {
        'xmlns': 'jabber:iq:version',
      });
    });
    return builder.buildDocument();
  }

  /// Create a time IQ query
  ///
  /// [iqId] - Unique identifier for the IQ
  /// [fromJid] - Sender's JID
  /// [toJid] - Target JID to query
  static XmlDocument createTimeQuery({
    required String iqId,
    required String fromJid,
    required String toJid,
  }) {
    final builder = XmlBuilder();
    builder.element('iq', attributes: {
      'xmlns': 'jabber:client',
      'id': iqId,
      'type': 'get',
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      builder.element('time', attributes: {
        'xmlns': 'urn:xmpp:time',
      });
    });
    return builder.buildDocument();
  }

  /// Generate a unique ID for stanzas
  ///
  /// [prefix] - Optional prefix for the ID
  static String generateId([String prefix = 'fxmpp']) =>
      generateStanzaId(prefix);

  /// Create a MUC room message stanza (groupchat type)
  ///
  /// [messageId] - Unique identifier for the message
  /// [roomJid] - The JID of the room
  /// [fromJid] - Sender's JID
  /// [message] - The message content
  /// [subject] - Optional subject change
  /// [thread] - Optional thread identifier
  static XmlDocument createMucMessage({
    required String messageId,
    required String roomJid,
    required String fromJid,
    required String message,
    String? subject,
    String? thread,
  }) {
    final builder = XmlBuilder();
    builder.element('message', attributes: {
      'xmlns': 'jabber:client',
      'id': messageId,
      'type': 'groupchat',
      'from': fromJid,
      'to': roomJid,
    }, nest: () {
      if (subject != null && subject.isNotEmpty) {
        builder.element('subject', nest: subject);
      }
      builder.element('body', nest: message);
      if (thread != null && thread.isNotEmpty) {
        builder.element('thread', nest: thread);
      }
    });
    return builder.buildDocument();
  }

  /// Create a MUC private message stanza (chat type to participant)
  ///
  /// [messageId] - Unique identifier for the message
  /// [roomJid] - The JID of the room
  /// [nickname] - The nickname of the participant
  /// [fromJid] - Sender's JID
  /// [message] - The message content
  /// [thread] - Optional thread identifier
  static XmlDocument createMucPrivateMessage({
    required String messageId,
    required String roomJid,
    required String nickname,
    required String fromJid,
    required String message,
    String? thread,
  }) {
    final builder = XmlBuilder();
    builder.element('message', attributes: {
      'xmlns': 'jabber:client',
      'id': messageId,
      'type': 'chat',
      'from': fromJid,
      'to': '$roomJid/$nickname',
    }, nest: () {
      builder.element('body', nest: message);
      if (thread != null && thread.isNotEmpty) {
        builder.element('thread', nest: thread);
      }
    });
    return builder.buildDocument();
  }

  // ============================================================================
  // MUC (Multi-User Chat) CONVENIENCE METHODS
  // ============================================================================

  /// Join a MUC room
  ///
  /// [roomJid] - The JID of the room to join (room@server)
  /// [nickname] - The nickname to use in the room
  /// [password] - Optional room password
  /// [maxStanzas] - Maximum number of history messages to request
  /// [since] - Request history since this date
  Future<bool> joinMucRoom({
    required String roomJid,
    required String nickname,
    String? password,
    int? maxStanzas,
    DateTime? since,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Joining room $roomJid as $nickname");
    _mucManager.registerRoom(roomJid: roomJid, nickname: nickname);
    return await FxmppPlatform.instance.joinMucRoom(
      roomJid: roomJid,
      nickname: nickname,
      password: password,
      maxStanzas: maxStanzas,
      since: since,
    );
  }

  /// Leave a MUC room
  ///
  /// [roomJid] - The JID of the room to leave
  /// [reason] - Optional reason for leaving
  Future<bool> leaveMucRoom({
    required String roomJid,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Leaving room $roomJid");
    return await FxmppPlatform.instance.leaveMucRoom(
      roomJid: roomJid,
      reason: reason,
    );
  }

  /// Create a new MUC room
  ///
  /// [roomJid] - The JID of the room to create (room@server)
  /// [nickname] - The nickname to use in the room
  /// [password] - Optional room password
  Future<bool> createMucRoom({
    required String roomJid,
    required String nickname,
    String? password,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Creating room $roomJid");
    _mucManager.registerRoom(roomJid: roomJid, nickname: nickname);
    return await FxmppPlatform.instance.createMucRoom(
      roomJid: roomJid,
      nickname: nickname,
      password: password,
    );
  }

  /// Send a message to a MUC room
  ///
  /// [message] - The XML document representing the message stanza
  Future<bool> sendMucMessage(XmlDocument message) async {
    if (kDebugMode) log("[XMPP-MUC] >>> ${message.toXmlString()}");
    return await FxmppPlatform.instance.sendMucMessage(message);
  }

  /// Send a private message to a room participant
  ///
  /// [message] - The XML document representing the private message stanza
  Future<bool> sendMucPrivateMessage(XmlDocument message) async {
    if (kDebugMode) log("[XMPP-MUC-Private] >>> ${message.toXmlString()}");
    return await FxmppPlatform.instance.sendMucPrivateMessage(message);
  }

  /// Change room subject/topic
  ///
  /// [roomJid] - The JID of the room
  /// [subject] - The new subject
  Future<bool> changeMucSubject({
    required String roomJid,
    required String subject,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Changing subject in room $roomJid to: $subject");
    return await FxmppPlatform.instance.changeMucSubject(
      roomJid: roomJid,
      subject: subject,
    );
  }

  /// Kick a participant from the room
  ///
  /// [roomJid] - The JID of the room
  /// [nickname] - The nickname of the participant to kick
  /// [reason] - Optional reason for kicking
  Future<bool> kickMucParticipant({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Kicking $nickname from room $roomJid");
    return await FxmppPlatform.instance.kickMucParticipant(
      roomJid: roomJid,
      nickname: nickname,
      reason: reason,
    );
  }

  /// Ban a user from the room
  ///
  /// [roomJid] - The JID of the room
  /// [userJid] - The JID of the user to ban
  /// [reason] - Optional reason for banning
  Future<bool> banMucUser({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Banning $userJid from room $roomJid");
    return await FxmppPlatform.instance.banMucUser(
      roomJid: roomJid,
      userJid: userJid,
      reason: reason,
    );
  }

  /// Grant voice to a participant (make them participant)
  ///
  /// [roomJid] - The JID of the room
  /// [nickname] - The nickname of the participant
  /// [reason] - Optional reason
  Future<bool> grantMucVoice({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Granting voice to $nickname in room $roomJid");
    return await FxmppPlatform.instance.grantMucVoice(
      roomJid: roomJid,
      nickname: nickname,
      reason: reason,
    );
  }

  /// Revoke voice from a participant (make them visitor)
  ///
  /// [roomJid] - The JID of the room
  /// [nickname] - The nickname of the participant
  /// [reason] - Optional reason
  Future<bool> revokeMucVoice({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Revoking voice from $nickname in room $roomJid");
    return await FxmppPlatform.instance.revokeMucVoice(
      roomJid: roomJid,
      nickname: nickname,
      reason: reason,
    );
  }

  /// Grant moderator privileges to a participant
  ///
  /// [roomJid] - The JID of the room
  /// [nickname] - The nickname of the participant
  /// [reason] - Optional reason
  Future<bool> grantMucModerator({
    required String roomJid,
    required String nickname,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Granting moderator to $nickname in room $roomJid");
    return await FxmppPlatform.instance.grantMucModerator(
      roomJid: roomJid,
      nickname: nickname,
      reason: reason,
    );
  }

  /// Grant membership to a user
  ///
  /// [roomJid] - The JID of the room
  /// [userJid] - The JID of the user to make member
  /// [reason] - Optional reason
  Future<bool> grantMucMembership({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Granting membership to $userJid in room $roomJid");
    return await FxmppPlatform.instance.grantMucMembership(
      roomJid: roomJid,
      userJid: userJid,
      reason: reason,
    );
  }

  /// Grant admin privileges to a user
  ///
  /// [roomJid] - The JID of the room
  /// [userJid] - The JID of the user to make admin
  /// [reason] - Optional reason
  Future<bool> grantMucAdmin({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Granting admin to $userJid in room $roomJid");
    return await FxmppPlatform.instance.grantMucAdmin(
      roomJid: roomJid,
      userJid: userJid,
      reason: reason,
    );
  }

  /// Invite a user to the room
  ///
  /// [roomJid] - The JID of the room
  /// [userJid] - The JID of the user to invite
  /// [reason] - Optional invitation message
  Future<bool> inviteMucUser({
    required String roomJid,
    required String userJid,
    String? reason,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Inviting $userJid to room $roomJid");
    return await FxmppPlatform.instance.inviteMucUser(
      roomJid: roomJid,
      userJid: userJid,
      reason: reason,
    );
  }

  /// Destroy a room (owner only)
  ///
  /// [roomJid] - The JID of the room to destroy
  /// [reason] - Optional reason for destruction
  /// [alternativeRoom] - Optional alternative room JID
  Future<bool> destroyMucRoom({
    required String roomJid,
    String? reason,
    String? alternativeRoom,
  }) async {
    if (kDebugMode) log("[XMPP-MUC] Destroying room $roomJid");
    return await FxmppPlatform.instance.destroyMucRoom(
      roomJid: roomJid,
      reason: reason,
      alternativeRoom: alternativeRoom,
    );
  }

  /// Get all joined MUC rooms
  List<MucRoom> get joinedMucRooms => _mucManager.joinedRooms;

  /// Get all MUC rooms (joined and not joined)
  List<MucRoom> get allMucRooms => _mucManager.allRooms;

  /// Get a MUC room by JID
  MucRoom? getMucRoom(String roomJid) => _mucManager.getRoom(roomJid);

  /// Check if user is in a MUC room
  bool isInMucRoom(String roomJid) => _mucManager.isInRoom(roomJid);
}
