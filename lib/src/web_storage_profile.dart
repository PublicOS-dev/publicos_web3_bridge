import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

/// Profile ids for engine storage: the partition unit is the SESSION address,
/// the same key `ConnectedSites` partitions grants on, LOWERCASED.
///
/// Lowercase, not EIP-55: the apps already hand the grant store a lowercased
/// session address, and on Windows an id becomes a folder name on a
/// case-insensitive filesystem -- two spellings of one key must never become
/// two jars. Every id is filesystem-safe by construction: `0x` + 40 hex,
/// optionally prefixed `wallet-`. No colon, no slash, no case.
class WebStorageProfileId {
  WebStorageProfileId._();

  /// The jar an account's browser tabs and app cards share.
  static String account(String sessionAddress) => _norm(sessionAddress);

  /// The jar the wallet-manager sheet gets, so the wallet dApp never shares
  /// cookies with an app tab of the same account.
  static String wallet(String sessionAddress) =>
      'wallet-${_norm(sessionAddress)}';

  static final RegExp _address = RegExp(r'^0x[0-9a-f]{40}$');

  static String _norm(String sessionAddress) {
    final a = sessionAddress.trim().toLowerCase();
    if (!_address.hasMatch(a)) {
      throw ArgumentError.value(
        sessionAddress,
        'clientAddress',
        'not a session address',
      );
    }
    return a;
  }

  /// Namespace for [uuidFor]. Fixed forever: changing it orphans every
  /// persisted WebKit store on every device.
  static const String namespace = '4b2c6f8e-1d3a-5e7b-9c0d-2f4a6b8c0e1d';

  /// Deterministic UUID (RFC 4122 v5) for engines that key a store by UUID --
  /// WebKit's `WKWebsiteDataStore(forIdentifier:)`. Same id, same UUID, every
  /// launch, on every device.
  static String uuidFor(String profileId) => uuidV5(namespace, profileId);
}

/// RFC 4122 v5: SHA-1 over (namespace bytes ++ name), version and variant
/// bits set. Hand-rolled on the SHA-1 this package already has through
/// pointycastle rather than adding a `uuid` dependency for one function.
String uuidV5(String namespaceUuid, String name) {
  final input = Uint8List.fromList(<int>[
    ..._bytesOfUuid(namespaceUuid),
    ...utf8.encode(name),
  ]);
  final hash = SHA1Digest().process(input);
  final b = Uint8List.fromList(hash.sublist(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50; // version 5
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

Uint8List _bytesOfUuid(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw ArgumentError.value(uuid, 'uuid', 'not a UUID');
  }
  return Uint8List.fromList(<int>[
    for (var i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The fifth seam: engine storage -- cookies, localStorage, IndexedDB, cache
/// -- partitioned per profile.
///
/// The bridge already partitions GRANTS by session address; the engine's
/// storage is one-per-process on every platform unless the engine is told
/// otherwise, and the three engines are told at three different moments
/// (WebKit on the configuration before the view exists, Android after
/// construction but before the first load, WebView2 at `initialize()`). So
/// the seam BUILDS the controller rather than handing back parameters.
///
/// [C] is the engine's controller type -- `WebViewController` on
/// `webview_flutter`, `WebviewController` on `zero_webview_windows`. The
/// bridge never names either; the apps do, in their `web3_adapters.dart`.
abstract class WebStorageProfile<C> {
  /// Whether this engine, on this device, can give each profile its own
  /// storage. `false` on exactly one engine we ship to: Android WebView
  /// below 121 (no `MULTI_PROFILE`). When false, [createController] returns
  /// a controller on the process-wide jar and the app must wipe that jar at
  /// every account boundary -- see the app's boot guard.
  Future<bool> get isolates;

  /// An engine controller whose storage belongs to [profileId] alone
  /// (when [isolates]), configured and ready for the app to wire up. The
  /// app applies its own settings and the first load after this returns.
  Future<C> createController(String profileId);

  /// The fallback: clear cookies, storage and cache for the whole process.
  /// Only meaningful where [isolates] is false; an engine that always
  /// isolates may throw [StateError] here rather than pretend.
  Future<void> wipeAll();
}
