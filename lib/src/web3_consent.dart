// EtherAmount comes from `wallet`, not `web3dart` -- same choice the client
// widget makes (`import 'package:wallet/wallet.dart' show EtherAmount`), kept
// identical so the lifted code needs no value conversion at the seam.
import 'package:wallet/wallet.dart' show EtherAmount;

import 'wallet_binding.dart';

/// What kind of thing the page is asking the user to sign.
enum SignatureKind {
  /// `personal_sign` -- a plain message, EIP-191 prefixed.
  message,

  /// `eth_sign` -- the legacy blind-signing method.
  ///
  /// Kept distinct from [message] on purpose. It signs whatever it is handed
  /// with no prefix guaranteeing the payload is not a transaction, which is
  /// why every wallet warns harder about it than about `personal_sign`.
  /// Collapsing the two would silently drop that warning.
  legacyEthSign,

  /// `eth_signTypedData` v1/v3/v4 -- structured data.
  typedData,

  /// `eth_signTransaction` -- signed, handed back, not broadcast.
  transaction,

  /// `eth_sendTransaction` -- signed AND broadcast. The only kind that moves
  /// value without a second step, and the one the sheet must be loudest about.
  sendTransaction,
}

/// A page asking to see who the user is -- or the user re-opening the picker
/// for a site that is already connected.
///
/// The answer is a **set of addresses**, not a yes/no, because permission is
/// per-site and per-key: the same sheet grants, adds, removes and (by
/// unchecking everything) disconnects.
class ConnectRequest {
  /// The document's origin, as the page sees it. This is the identity the
  /// grant is recorded against -- never a display title the page controls.
  final Uri origin;

  /// Every key the user could offer this site, in the order the picker should
  /// list them. A pinned view supplies exactly one.
  final List<WalletKey> keys;

  /// The addresses this site already holds. The picker opens with these
  /// checked, which is what makes one sheet serve both "connect" and "manage".
  final Set<String> alreadyGranted;

  /// The globally preferred key, for a "preferred" marker on its row. It is
  /// **not** a default grant: an unchecked preferred key stays unchecked.
  final String? preferred;

  /// Set when the site named an address it does not yet hold -- a signature
  /// request for a key we have but have not granted. The sheet pre-checks it
  /// and can say why the picker appeared.
  ///
  /// This is the deliberate divergence from EIP-1193, which says answer 4100.
  /// The security property survives (the user approves the connect, then
  /// approves the signature) and the alternative is a dead end: the dApp asked
  /// for a key we hold and there was no way to say yes.
  final String? requested;

  /// The site's own ACTIVE key, lowercased, or null when the site has no
  /// choice of its own and the global [preferred] orders it. Display only here: the picker shows the green key glyph on
  /// the row the site will see first.
  final String? activeKey;
  const ConnectRequest({
    required this.origin,
    required this.keys,
    this.alreadyGranted = const {},
    this.preferred,
    this.requested,
    this.activeKey,
  });
}

/// The picker's answer.
///
/// [visible] is the grant set — every key the site may see and ask to sign
/// with. **Empty is the disconnect gesture**, not refusal; refusal is a null
/// decision. [activeKey] is the user's explicit per-site choice for
/// `accounts[0]`, or null for "no choice of its own" (the global preferred
/// key orders the list). It must be a member of [visible]; the gate ignores
/// it otherwise, since an active key that is not visible is unconstructible
/// by design (the flag lives on the grant row).
class ConnectDecision {
  final Set<String> visible;
  final String? activeKey;
  const ConnectDecision({required this.visible, this.activeKey});
}

/// A page asking for a signature.
class SignatureRequest {
  final Uri origin;
  final SignatureKind kind;
  final String address;

  /// Human-readable rendering of what is being signed. For a message, the
  /// decoded text; for typed data, the pretty-printed struct; for a
  /// transaction, the to/value/data summary.
  final String display;

  /// The raw payload, for a caller that wants to render its own view.
  final Object? payload;

  /// Set for [SignatureKind.transaction] and [SignatureKind.sendTransaction].
  final EtherAmount? value;
  final String? to;

  const SignatureRequest({
    required this.origin,
    required this.kind,
    required this.address,
    required this.display,
    this.payload,
    this.value,
    this.to,
  });
}

/// The consent seam.
///
/// The second place the clients genuinely differ: mobile asks through a bottom
/// sheet pushed on GoRouter, desktop through a glass dialog over
/// `InlineFlowHost`. Both answer the same two questions, so the bridge asks
/// them abstractly and never learns which chrome appeared.
///
/// Implementations must **default to refusal**: any path that does not produce
/// an explicit user "yes" -- dismissal, a lost route, an exception -- has to
/// return `false`. A bridge that treats silence as consent is a bridge that
/// signs transactions nobody approved.
abstract class Web3Consent {
  /// Ask which of the user's keys [request.origin] may learn about.
  ///
  /// Returns the approved SET -- which may legitimately be **empty**: that is
  /// the disconnect gesture (uncheck everything), and it is not the same
  /// answer as `null`, which is refusal. `setGrants` applies the difference in
  /// both directions, so a sheet returning a smaller set revokes.
  ///
  /// Called for a first connect, for `wallet_requestPermissions`, for the
  /// indicator tap, and when a signature names a key we hold but have not
  /// granted.
  Future<ConnectDecision?> requestConnect(ConnectRequest request);

  /// Ask whether to sign. Called for EVERY signature, every time -- signing is
  /// never covered by a standing grant, only address disclosure is.
  Future<bool> requestSignature(SignatureRequest request);
}
