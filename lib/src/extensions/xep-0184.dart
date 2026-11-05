import 'package:xml/xml.dart';

// ============================================================================
// XEP-0184: MESSAGE DELIVERY RECEIPTS UTILITY METHODS
// ============================================================================
class XEP_0184 {
  /// Create a message with delivery receipt request (XEP-0184)
  ///
  /// [messageId] - Unique identifier for the message (required for receipt tracking)
  /// [toJid] - Recipient's JID
  /// [fromJid] - Sender's JID
  /// [body] - The message content
  /// [thread] - Optional thread identifier
  /// [type] - Message type (defaults to 'chat')
  static XmlDocument createMessageWithReceiptRequest({
    required String messageId,
    required String toJid,
    required String fromJid,
    required String body,
    String? thread,
    String type = 'chat',
  }) {
    final builder = XmlBuilder();
    builder.element('message', attributes: {
      'xmlns': 'jabber:client',
      'id': messageId,
      'type': type,
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      builder.element('body', nest: body);
      if (thread != null && thread.isNotEmpty) {
        builder.element('thread', nest: thread);
      }
      // Add receipt request
      builder.element('request', attributes: {
        'xmlns': 'urn:xmpp:receipts',
      });
    });
    return builder.buildDocument();
  }

  /// Create a delivery receipt acknowledgment message (XEP-0184)
  ///
  /// [messageId] - Unique identifier for this receipt message
  /// [toJid] - Recipient's JID (original sender)
  /// [fromJid] - Sender's JID (original recipient)
  /// [originalMessageId] - The ID of the original message being acknowledged
  /// [thread] - Optional thread identifier
  /// [type] - Message type (should match original message type)
  static XmlDocument createDeliveryReceipt({
    required String messageId,
    required String toJid,
    required String fromJid,
    required String originalMessageId,
    String? thread,
    String type = 'chat',
  }) {
    final builder = XmlBuilder();
    builder.element('message', attributes: {
      'xmlns': 'jabber:client',
      'id': messageId,
      'type': type,
      'from': fromJid,
      'to': toJid,
    }, nest: () {
      if (thread != null && thread.isNotEmpty) {
        builder.element('thread', nest: thread);
      }
      // Add receipt acknowledgment
      builder.element('received', attributes: {
        'xmlns': 'urn:xmpp:receipts',
        'id': originalMessageId,
      });
    });
    return builder.buildDocument();
  }

  /// Add a receipt request to an existing message XML
  ///
  /// [messageXml] - The existing message XML document
  /// Returns a new XmlDocument with the receipt request added
  static XmlDocument addReceiptRequestToMessage(XmlDocument messageXml) {
    // Deep-copy the original message verbatim (prefixes, namespaces and
    // CDATA included) and append the receipt request.
    final doc = messageXml.copy();
    final builder = XmlBuilder();
    builder.element('request', attributes: {'xmlns': 'urn:xmpp:receipts'});
    doc.rootElement.children
        .addAll(builder.buildFragment().children.map((node) => node.copy()));
    return doc;
  }
}
