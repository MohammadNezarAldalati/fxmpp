# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

fxmpp is a Flutter plugin providing XMPP (Extensible Messaging and Presence Protocol) communication for iOS, Android, and Web. It is a fork of [haithngn/fxmpp](https://github.com/haithngn/fxmpp). The plugin exposes a stream-based Dart API. On iOS/Android it bridges to native XMPP libraries via Flutter's platform channel mechanism; on Web it speaks XMPP-over-WebSocket directly in Dart with no native/JS XMPP dependency.

## Build & Development Commands

```bash
# Get dependencies
flutter pub get

# Run the example app
cd example && flutter run

# Analyze Dart code
flutter analyze

# Run tests (no test directory currently exists)
flutter test
```

iOS native dependencies are managed via CocoaPods (`ios/fxmpp.podspec`) or Swift Package Manager (`ios/fxmpp/Package.swift`) — both point at the same source in `ios/fxmpp/Sources/fxmpp/`. Android dependencies are in `android/build.gradle`. Neither requires manual setup beyond `flutter pub get`.

## Architecture

### Platform interface + three implementations

1. **Dart API layer** (`lib/src/fxmpp.dart`) — `Fxmpp` singleton exposing streams and async methods. This is the public interface consumers use. It also contains static stanza builder methods (`createMessage`, `createPresence`, `createIq`, `createMucMessage`, etc.).

2. **Platform interface** (`lib/src/fxmpp_platform_interface.dart`) — Abstract contract using `plugin_platform_interface`. Defines every method a platform implementation must provide. `FxmppPlatform.instance` defaults to `MethodChannelFxmpp` and is swapped for `FxmppWeb` on web via `registerWith`.

3. Three implementations of that interface, registered per-platform in `pubspec.yaml`'s `flutter.plugin.platforms`:
   - **Method channel** (`lib/src/fxmpp_method_channel.dart`) — bridges Dart to native Android/iOS via `MethodChannel('fxmpp')` for request/response calls (connect, send, MUC operations) and `EventChannel`s for streamed data from native: `fxmpp/connection_state`, `fxmpp/messages`, `fxmpp/presence`, `fxmpp/iq`, `fxmpp/muc_events`.
   - **Android** (`android/.../FxmppPlugin.kt`) — Uses [Smack](https://github.com/igniterealtime/Smack) library. Networking runs on background `Thread`s, results posted to main via `Handler(Looper.getMainLooper())`. Stanzas are sent by parsing XML strings with `PacketParserUtils.parseStanza()`.
   - **iOS** (`ios/fxmpp/Sources/fxmpp/FxmppPlugin.swift`) — Uses [XMPPFramework](https://github.com/robbiehanson/XMPPFramework) (~> 4.0/4.1). Stanzas are sent by parsing XML strings into `DDXMLElement`. MUC admin operations (kick, ban, grant roles) are implemented as manually-constructed IQ stanzas since XMPPFramework lacks direct methods for them.
   - **Web** (`lib/src/fxmpp_web.dart`) — No method channel involved; this class implements `FxmppPlatform` directly in pure Dart using XMPP-over-WebSocket (RFC 7395). Helpers live in `lib/src/web/`: `XmppWebSocket` (thin wrapper over `package:web`'s browser WebSocket, one frame = one XML element), `XmppStreamHandler` (stream negotiation: open → SASL PLAIN auth → re-open → resource bind), and `SaslPlain` (RFC 4616 encoder). Requires `wsUrl` in `XmppConnectionConfig`; MUC operations are sent as raw XMPP stanzas over the same socket rather than through separate APIs.

### Key design pattern: XML-centric stanza passing

All stanzas (messages, presence, IQ) are built as `XmlDocument`s on the Dart side. On Android/iOS they're serialized to XML strings, passed through the method channel as `{'xml': xmlString}`, and parsed back to native stanza objects (reverse path for incoming stanzas). On Web, `XmlDocument`s are serialized straight onto the WebSocket and incoming frames are parsed with `XmlDocument.parse`. The `xml` Dart package is re-exported from the library for consumers.

### Connection state mapping

Native platforms emit integer state codes through the `fxmpp/connection_state` EventChannel, mapped to `XmppConnectionState` enum indices: 0=disconnected, 1=connecting, 2=connected, 4=error, 5=authenticationFailed, 6=connectionLost. On Web, `FxmppWeb` invokes the state callback directly with `XmppConnectionState` values (no integer encoding).

### Core models (`lib/src/core/`)

Connection config/state and stanza enums (`message_type`, `presence_type`, `iq_type`) plus MUC value types (`muc_room`, `muc_participant`, `muc_role`, `muc_affiliation`), all re-exported from `lib/fxmpp.dart`.

### XEP extensions (`lib/src/extensions/`)

Static utility classes that build XmlDocument stanzas for specific XMPP extensions. Each file is a self-contained stanza builder (no state, no side effects):
- XEP-0012 (Last Activity), XEP-0085 (Chat State), XEP-0184 (Delivery Receipts), XEP-0313 (MAM), XEP-0424 (Message Retraction)

### MUC (Multi-User Chat)

`MucManager` (`lib/src/muc_manager.dart`) maintains local room/participant state and builds MUC-specific stanzas. The `Fxmpp` class delegates MUC operations to both `MucManager` (for stanza building) and `FxmppPlatform` (for execution — native method channel on Android/iOS, raw WebSocket stanzas on Web). MUC events from native flow through the `fxmpp/muc_events` EventChannel; on Web, MUC events arrive as ordinary presence/message stanzas rather than a distinct event stream.
