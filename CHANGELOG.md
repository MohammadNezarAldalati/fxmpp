# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.5] - 2026-08-02

### Changed
- **Android Gradle build migrated to Kotlin DSL**: `android/build.gradle` is replaced by `android/build.gradle.kts`, and a new `android/settings.gradle.kts` declares `rootProject.name`. The layout now follows the Flutter 3.44.8 plugin template: Android Gradle Plugin 9.0.1 and Kotlin 2.3.20 on the `buildscript` classpath, `compileSdk` 36, and `sourceCompatibility`/`targetCompatibility`/`jvmTarget` raised from Java 8 to Java 17. **This requires consuming apps to build with AGP 9.** A Flutter plugin's Android module is compiled as a subproject of the host app's Gradle build, so it is the app's AGP — not the version pinned here — that evaluates this file; apps still on AGP 8 will fail to configure the `:fxmpp` project.
- **Android now uses AGP's built-in Kotlin support**: the module applies only `com.android.library` and no longer applies the legacy `org.jetbrains.kotlin.android` plugin, configuring the compiler through the top-level `kotlin { compilerOptions { } }` block instead. Kotlin Gradle Plugin remains on the `buildscript` classpath but is never applied. This removes `fxmpp` from Flutter's "your app uses the following plugins that apply Kotlin Gradle Plugin (KGP)" warning, which future Flutter versions will escalate to a build failure.
- **BREAKING — Android `minSdk` raised from 16 to 30**: consuming apps must declare `minSdk` 30 (Android 11) or higher, otherwise manifest merging fails. This is well above Flutter's own floor of 24, so apps using the default `flutter.minSdkVersion` need an explicit override.

### Removed
- **Explicit `kotlin-stdlib-jdk7` dependency (Android)**: AGP's built-in Kotlin support contributes the standard library itself, and the `kotlin_version` value is not visible outside the `buildscript` block in the Kotlin DSL. Projects depending on the `jdk7` variant specifically being on fxmpp's classpath should declare it themselves.
- **`flutter_test` dev dependency**: the package ships no Dart tests, so the dependency only constrained resolution for consumers.

## [1.0.4] - 2026-08-01

### Fixed
- **Outgoing IQ payloads silently stripped (Android)**: `sendIq` reparsed the caller's XML with `PacketParserUtils.parseStanza` and transmitted the reconstructed object. When Smack has no `IQProvider` for the payload it falls back to `UnparsedIQ`, which re-serializes the child element by XML-*escaping* it into a text node — so the payload arrived as inert text with every attribute lost. XEP-0363 was the common casualty: Smack registers its provider only via `HttpFileUploadManager`, which this plugin never constructs, so upload slot requests reached the server carrying no `filename`, `size` or `content-type`, no slot was ever granted, and file uploads were impossible on Android. iOS/macOS were unaffected because they write the caller's XML to the stream verbatim. `sendIq` now detects the `UnparsedIQ` fallback and sends the original XML as-is; stanzas Smack parses successfully still go through `sendStanza` unchanged.

## [1.0.3] - 2026-08-01

### Fixed
- **Endless reconnect loop (iOS/macOS/Android)**: `connect` built a fresh stream/connection on every call but only retired the previous one when it happened to be connected at that instant. After a drop it was already disconnected, so it was orphaned rather than closed — still retained by its own modules, still holding this plugin as its delegate, and still able to log back in under the same resource as the new session. Servers that resolve resource conflicts by keeping the newest session (ejabberd's default) then evicted whichever session was older, and the two took turns kicking each other every few seconds. `connect` and `disconnect` now tear the previous stream down unconditionally: modules and joined rooms are deactivated, delegates/listeners detached, then the socket is closed.
- **Stale streams reaching Dart (iOS/macOS)**: stream delegate callbacks now ignore any stream that is no longer the live one, and act on the `sender` they were handed rather than on whichever stream is current. Previously a dying stream's `didConnect` could trigger an `authenticate` on the live one (surfacing to Dart as an `error` state), and its disconnect cleared `isConnected` for a healthy session.

### Removed
- **`XMPPReconnect` (iOS/macOS)**: reconnection is the caller's responsibility. The native reconnector redialed the same account behind Dart's back, racing the caller's own reconnect logic and producing the duplicate sessions described above. Apps that relied on it should drive `connect` from their own connection-state listener.

## [1.0.2] - 2026-07-24

### Added
- **macOS platform support**: Native macOS implementation that reuses the iOS XMPPFramework plugin over the same method channel — the Dart API is unchanged.
  - Swift Package Manager only (`macos/fxmpp/Package.swift`, macOS 10.15+). The Swift source is shared with iOS via a symlink into `ios/fxmpp/Sources/fxmpp/`, so both Apple platforms compile one file.
  - Consuming macOS apps must have Swift Package Manager enabled and add the `com.apple.security.network.client` sandbox entitlement for connections to work.

## [1.0.1] - 2026-07-24

### Added
- **Web platform support**: New pure-Dart implementation of `FxmppPlatform` (`FxmppWeb`) using XMPP-over-WebSocket (RFC 7395) — no native or JS XMPP dependency.
  - Stream negotiation with SASL PLAIN auth and resource binding (`lib/src/web/`).
  - Requires `wsUrl` in `XmppConnectionConfig` (e.g. `wss://example.com:5443/ws`).
  - MUC operations are sent as raw XMPP stanzas over the same WebSocket.
- **Swift Package Manager support**: iOS can now be built via `ios/fxmpp/Package.swift` in addition to CocoaPods; both reference the same source in `ios/fxmpp/Sources/fxmpp/`.

### Fixed
- **Android typing/signaling indicators**: Body-less signaling messages were dropped by Smack's `ChatManager`, which only delivers messages carrying a `<body>`. These are now forwarded to Dart's message stream, matching iOS behavior — covering XEP-0085 (chat states/typing), XEP-0184 (delivery receipts), XEP-0333 (read markers), and XEP-0444 (reactions). MAM `<result>` archive delivery is intentionally left untouched.
- **Example app**: Fixed a RenderFlex overflow error and migrated the iOS runner to the UI scene lifecycle.

## [1.0.0] - 2025-01-18

### Changed
- Bump version 1.0.0
  - Core XMPP features.
  - MUC.
  - Stanza Builders: IQ, Message, Presence, XEP-0012(Last Activity), XEP-0085(Chat State Notifications), XEP-0184(Message Delivery Receipts), XEP-0313(Message Archive Management).

## [1.0.0-alpha.2] - 2025-01-17

### Changed
- **BREAKING: MUC API Consistency**: Refactored MUC (Multi-User Chat) methods to accept `XmlDocument` objects instead of primitive types
  - `sendMucMessage()` now accepts `XmlDocument message` parameter
  - `sendMucPrivateMessage()` now accepts `XmlDocument message` parameter
  - This change ensures API consistency with existing `sendMessage()`, `sendPresence()`, and `sendIq()` methods

### Added
- **MUC Utility Methods**: New static methods for creating MUC XML stanzas
  - `Fxmpp.createMucMessage()` - Creates groupchat message stanzas for room messages
  - `Fxmpp.createMucPrivateMessage()` - Creates chat message stanzas for private messages to room participants
- **Enhanced Example App**: Updated MUC examples to demonstrate new API usage

### Migration Guide
- Replace `sendMucMessage(roomJid: string, message: string)` calls with:
  ```dart
  final mucMessage = Fxmpp.createMucMessage(
    messageId: Fxmpp.generateId('muc'),
    roomJid: roomJid,
    fromJid: senderJid,
    message: messageContent,
  );
  await fxmpp.sendMucMessage(mucMessage);
  ```
- Replace `sendMucPrivateMessage(roomJid: string, nickname: string, message: string)` calls with:
  ```dart
  final privateMessage = Fxmpp.createMucPrivateMessage(
    messageId: Fxmpp.generateId('muc_private'),
    roomJid: roomJid,
    nickname: targetNickname,
    fromJid: senderJid,
    message: messageContent,
  );
  await fxmpp.sendMucPrivateMessage(privateMessage);
  ```

## [1.0.0-alpha] - 2025-01-15

### Added
- **IQ Stanza Support**: Complete implementation of XMPP IQ (Info/Query) stanzas
  - Send and receive IQ stanzas with proper XML handling
  - Support for get, set, result, and error IQ types
  - Cross-platform implementation for both iOS and Android
- **Enhanced Example App**: New IQ tab with multiple IQ examples
  - Version IQ (`jabber:iq:version`)
  - Time IQ (`urn:xmpp:time`) with proper XML structure
  - Disco Info IQ (`http://jabber.org/protocol/disco#info`)
  - Ping IQ (`urn:xmpp:ping`)
  - Resource Bind IQ (`urn:ietf:params:xml:ns:xmpp-bind`)
  - Roster IQ (`jabber:iq:roster`) for contact list retrieval
- **Improved Debugging**: Enhanced logging for troubleshooting IQ communication
- **Platform-Specific Fixes**: 
  - iOS: Proper XMPPFramework delegate implementation for IQ handling
  - Android: Fixed XML parsing and stream handler consistency

### Fixed
- **XML Malformation**: Fixed Time IQ XML structure causing connection drops
- **Stream Handler Consistency**: Unified XML string handling across all stanza types
- **iOS IQ Reception**: Added missing IqStreamHandler class for iOS platform
- **Connection Stability**: Resolved XML parsing errors that caused XMPP disconnections

### Technical Improvements
- Stream-based IQ architecture matching message and presence patterns
- Proper XML namespace handling for different IQ types
- Enhanced error handling and debugging capabilities
- Cross-platform compatibility improvements

## [0.1.0] - 2024-12-09

### Added
- Initial release of FXMPP Flutter plugin
- Cross-platform XMPP support for iOS and Android
- Real-time messaging capabilities
- Presence management system
- Connection state monitoring with detailed states
- SSL/TLS encryption support
- Stream-based architecture for real-time updates
- Comprehensive example application
- iOS implementation using XMPPFramework
- Android implementation using Smack library
- Support for various message types (chat, groupchat, headline, normal, error)
- Support for presence types (available, unavailable, subscribe, etc.)
- Configurable connection parameters
- Self-signed certificate support for testing
- Resource management and cleanup
- Complete API documentation
- MIT License

### Features
- **Connection Management**: Connect/disconnect to XMPP servers with full configuration options
- **Real-time Messaging**: Send and receive messages with timestamp and type information
- **Presence System**: Send and receive presence updates with show states and status messages
- **Stream Architecture**: Event-driven architecture using Dart streams for real-time updates
- **Security**: SSL/TLS support with optional self-signed certificate handling
- **Cross-platform**: Native implementations for both iOS (XMPPFramework) and Android (Smack)
- **Example App**: Complete example application demonstrating all features

### Platform Support
- iOS 11.0+
- Android API 16+
- Flutter 3.3.0+
- Dart 3.0.0+
