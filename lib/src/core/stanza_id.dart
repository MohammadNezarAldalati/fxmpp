import 'dart:math';

final Random _random = Random.secure();

/// Generate a stanza id that is unique within this process.
///
/// Format: `<prefix>_<millisecondsSinceEpoch>_<32-bit random hex>`.
String generateStanzaId([String prefix = 'fxmpp']) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  // Not `1 << 32`: on web shifts are 32-bit, so that evaluates to 0 and
  // nextInt throws a RangeError.
  final random = _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
  return '${prefix}_${timestamp}_$random';
}
