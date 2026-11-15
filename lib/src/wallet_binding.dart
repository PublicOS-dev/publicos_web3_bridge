import 'package:web3dart/web3dart.dart';

/// One key the user holds, as the picker and the ordering rule see it.
///
/// [label] is DISPLAY ONLY -- `null` (or `'session'`) means the session key. The
/// identity is always [address]; a rename is not a new identity, which is the
/// same rule the grant table follows.
class WalletKey {
  final String? label;

  /// Lowercased on construction, because every comparison in this package --
  /// grant lookups, `from`/`p.address` matching, set membership -- is a plain
  /// string equality and a mixed-case address would silently miss.
  final String address;

  /// The key's emoji, as the keychain stores it. DISPLAY ONLY, exactly like
  /// [label] -- nothing here ever reads it.
  ///
  /// It rides along rather than being fetched by the picker because the app's
  /// binding has just read the keychain to build this list, and `fetchKeys`
  /// decrypts every private key on every call. A second pass purely for
  /// cosmetics would double that cost on every connect prompt.
  final String? emoji;

  WalletKey({
    required this.label,
    required String address,
    this.emoji,
  }) : address = address.toLowerCase();

  /// True for the session key, which [label] spells as `null` or `'session'`
  /// depending on whether the pointer was ever explicitly set. Both spellings
  /// mean the same key, so no caller may compare labels directly.
  bool get isSessionKey => label == null || label == 'session';

  @override
  bool operator ==(Object other) =>
      other is WalletKey && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'WalletKey(${label ?? 'session'}, $address)';
}

/// Which keys this view may offer, which one comes first, and what signs.
///
/// Abstract on purpose. This package never reaches into Core: the flow is
/// **webview <-> app <-> core**, so the app resolves keys and hands the answer
/// down. Two reasons that matters beyond tidiness:
///
/// * the wallet-manager surface pins a webview to a *specific* wallet rather
///   than to the keychain, and that must not be a special case threaded through
///   the dispatch -- it is just a different binding;
/// * a binding is trivially fakeable, so the dispatch is testable without a
///   keychain, a database or a device.
///
/// ── PERMISSION IS A SET, THE POINTER IS A PREFERENCE ────────────────────────
///
/// A single global web-key pointer resolving to ONE address and ONE key would
/// do permission's job as well as ordering's, and its cross-product with a
/// per-(site, key) grant table produces states no user can reason about.
///
/// Permission is a **per-site set**; the global pointer is only a
/// **preference** that decides which permitted key is `accounts[0]`. Hence
/// three questions, and the middle one is explicitly ordering-only.
abstract class WalletBinding {
  /// Every key this view could offer -- the picker's source, and the tiebreak
  /// order for `accounts[0]`.
  ///
  /// Order is the app's to decide and is honoured verbatim (session key first,
  /// then the keychain's own order). Never sort by grant recency: see
  /// [ConnectGate.orderAccounts].
  Future<List<WalletKey>> availableKeys();

  /// The globally preferred key's address, lowercased. **Ordering only.**
  ///
  /// It grants nothing: a preference for a key this site was never given is
  /// simply ignored. `null` means "no preference" and the first available key
  /// wins.
  Future<String?> preferredAddress();

  /// The key that signs for [address], or `null` if we do not hold it.
  ///
  /// **Exact match or null.** Substituting another key here -- the session key
  /// in particular -- means signing as an identity the page was never told
  /// about, producing a signature that does not recover to the address the
  /// dApp asked for: the address would be parsed, displayed in the consent
  /// sheet, then ignored at signing time.
  Future<EthPrivateKey?> signingKeyFor(String address);
}

/// Per-origin connect grants: the record of "this site may see this account".
///
/// The store itself lives in the app's database. This package only states the
/// questions the gate needs to ask, so the grant table stays entirely an
/// app-and-Core concern.
///
/// A grant covers **address disclosure only**. It is never permission to sign:
/// every signature is asked for separately, every time.
///
/// Several rows per origin has always been legal -- the table's unique key is
/// `{origin, session, eoa}` -- so the set model fits the storage as it is;
/// [listGrants] and [revokeSite] expose what the storage already supports.
abstract class GrantStore {
  /// Does [origin] hold a grant for this exact (session, account) triple?
  Future<bool> hasGrant({
    required String origin,
    required String session,
    required String eoa,
  });

  /// Every account [origin] may see under [session], lowercased. Unordered --
  /// [ConnectGate.orderAccounts] decides what the page is shown first.
  Future<List<String>> listGrants({
    required String origin,
    required String session,
  });

  /// Record a fresh grant, after the user approved the picker.
  Future<void> grantSite({
    required String origin,
    required String session,
    required String eoa,
    String? keyLabel,
  });

  /// Drop exactly one (origin, session, eoa) row. A site connected under two
  /// keys keeps its other grant.
  Future<void> revokeSite({
    required String origin,
    required String session,
    required String eoa,
  });

  /// Bump the sort key on an existing grant, so a "connected sites" list can
  /// order by real use rather than by when it was first approved.
  Future<void> touchGrant({
    required String origin,
    required String session,
    required String eoa,
  });

  /// The site's ACTIVE key under [session], lowercased — the address it sees
  /// first — or null when the site has no choice of its own and the global
  /// preferred key orders the list.
  Future<String?> activeKeyFor({
    required String origin,
    required String session,
  });

  /// Make [eoa] the site's active key. The store keeps the flag ON the grant
  /// row, so an ungranted [eoa] is a no-op rather than a dangling pointer, and
  /// a later revoke of that grant drops the choice with it.
  Future<void> setActiveKey({
    required String origin,
    required String session,
    required String eoa,
  });

  /// Drop the site's choice; it falls back to the global preferred key.
  Future<void> clearActiveKey({
    required String origin,
    required String session,
  });
}

/// A binding pinned to one wallet, ignoring the keychain entirely.
///
/// Used by the wallet-manager surface: [address] is the wallet's address (a
/// Safe address for a Safe, the EOA for a keychain key) and [signingKey] is
/// what signs for it -- for a Safe that is the account owner key, since
/// EIP-1271 / Safe routing is still deferred.
///
/// **A manager for one wallet forces that wallet.** [availableKeys] is the pin
/// alone, so the picker has exactly one row and there is nothing to choose;
/// [signingKeyFor] refuses any other address rather than falling through to a
/// keychain this view is not speaking for.
///
/// Kept in the package rather than the apps because it needs nothing from
/// Core: it is handed its values already resolved.
class PinnedWalletBinding implements WalletBinding {
  final String address;
  final EthPrivateKey? signingKey;
  final String? keyLabel;

  const PinnedWalletBinding({
    required this.address,
    required this.signingKey,
    this.keyLabel,
  });

  @override
  Future<List<WalletKey>> availableKeys() async => address.isEmpty
      ? const []
      : [WalletKey(label: keyLabel, address: address)];

  @override
  Future<String?> preferredAddress() async =>
      address.isEmpty ? null : address.toLowerCase();

  @override
  Future<EthPrivateKey?> signingKeyFor(String a) async =>
      a.toLowerCase() == address.toLowerCase() ? signingKey : null;
}
