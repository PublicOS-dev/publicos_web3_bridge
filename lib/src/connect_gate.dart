import 'wallet_binding.dart';
import 'web3_channel.dart';
import 'web3_consent.dart';
import 'web3_error.dart';

/// The consent core: which keys this page may see, and how it gets them.
///
/// Everything about account disclosure lives here, in one object, on purpose.
/// The picker and the provider read the SAME set through the same methods, so
/// the sheet asking about one thing while the provider hands over another is
/// structurally impossible.
///
/// The provider is injected **identity-less** and a page must ASK. A grant
/// covers address disclosure only, never signing.
///
/// -- PERMISSION IS A SET ----------------------------------------------------
///
/// A site's permission is a **set of keys**, and the global web-key pointer is
/// only a **preference** deciding which permitted key is `accounts[0]`. This is
/// MetaMask's actual shape, and it is what the storage always allowed:
/// `ConnectedSites` is keyed `{origin, session, eoa}`, so N keys per origin has
/// always been legal.
///
/// A one-key-per-site shape produces states no user can reason about: a grant
/// that exists but "does not apply" because it was made with a key that is not
/// the selected one, and a site whose connect button is inert because *some*
/// grant exists, for the wrong key.
class ConnectGate {
  final WalletBinding wallet;
  final GrantStore grants;
  final Web3Consent consent;
  final Web3Channel channel;

  /// The logged-in session address -- the grant's scope.
  ///
  /// Session, not account: a user can hold several sessions for one account on
  /// one device, and an account-scoped grant cannot tell them apart. Passed in
  /// already resolved, because deciding it is the app's job.
  final String sessionAddress;

  /// Reports connection changes so the host can light or hide its indicator.
  /// A connect *event*, never a bare tab re-display.
  final void Function(bool connected)? onConnectionChanged;

  /// The address the page now sees first (`accounts[0]`), or null when it
  /// sees none — fired beside [onConnectionChanged] so chrome can show WHICH
  /// key a site is using, not just that one is.
  final void Function(String? address)? onActiveAccountChanged;

  final void Function(String message)? log;

  ConnectGate({
    required this.wallet,
    required this.grants,
    required this.consent,
    required this.channel,
    required this.sessionAddress,
    this.onConnectionChanged,
    this.onActiveAccountChanged,
    this.log,
  });

  // -- reads ----------------------------------------------------------------

  /// Is this site connected AT ALL? Drives the indicator, nothing else.
  ///
  /// Deliberately split from [hasGrantFor]: the icon answers "does this site
  /// have any relationship with me", signing answers "may it use THIS key".
  /// Conflating them is what made a site's own connect button inert while its
  /// actual request was still unauthorised.
  ///
  /// A null origin is DENIED. Failing closed is the only safe direction here.
  Future<bool> hasAnyGrant(Uri? origin) async {
    if (origin == null) return false;
    final granted = await _rawGrants(origin);
    return granted.isNotEmpty;
  }

  /// May [origin] use this exact key? The predicate every signing path runs.
  Future<bool> hasGrantFor(Uri? origin, String address) async {
    if (origin == null || address.isEmpty) return false;
    return grants.hasGrant(
      origin: originKey(origin),
      session: sessionAddress,
      eoa: address.toLowerCase(),
    );
  }

  /// `eth_accounts` -- the PASSIVE READ. Never prompts.
  ///
  /// Returns `[]` until granted. That emptiness is the EIP-1193 split which
  /// makes `eth_requestAccounts` the sole door; a dApp reading this before
  /// connecting is supposed to see nothing.
  Future<List<String>> grantedAccounts(Uri? origin) async {
    if (origin == null) return const [];
    final granted = await _rawGrants(origin);
    if (granted.isEmpty) return const [];

    final ordered = await orderAccounts(origin, granted);

    // Bump the sort key so a "connected sites" list can order by real use
    // rather than by first approval. Note what this does to `lastUsedAt`: it
    // now means "when the site last looked", identically across all of that
    // site's keys -- see [orderAccounts].
    for (final eoa in ordered) {
      await grants.touchGrant(
        origin: originKey(origin),
        session: sessionAddress,
        eoa: eoa,
      );
    }
    return ordered;
  }

  /// Decide `accounts[0]`: the site's own ACTIVE key if it still holds it,
  /// else the global preferred key if this site holds it, otherwise the first
  /// permitted key in [WalletBinding.availableKeys] order.
  ///
  /// The active key is a per-site choice kept on the grant row, so it is visible by construction and dies with a revoke;
  /// the preferred key is the global pointer and only ever the fallback.
  ///
  /// > **Never order by `lastUsedAt`.** [grantedAccounts] touches every grant
  /// > on every `eth_accounts` read, so that column means *"when the site last
  /// > looked"* and is identical across a site's keys -- it would order by
  /// > nothing at all. Worse, most dApps treat `accounts[0]` as THE identity,
  /// > so an unstable first element is an identity that changes across
  /// > reloads.
  ///
  /// A granted key we no longer hold (deleted from the keychain) sorts last
  /// rather than being dropped: the grant is still real, and silently hiding
  /// it would make a "connected sites" list disagree with the provider.
  Future<List<String>> orderAccounts(
    Uri origin,
    Iterable<String> granted,
  ) async {
    final set = granted.map((a) => a.toLowerCase()).toSet();
    if (set.length <= 1) return set.toList();

    final keys = await wallet.availableKeys();
    final head = await activeAccount(origin, set);

    final ordered = <String>[
      ?head,
      for (final k in keys)
        if (set.contains(k.address) && k.address != head) k.address,
    ];
    // Anything granted that no longer matches a held key, appended in stable
    // set order rather than dropped.
    ordered.addAll(set.where((a) => !ordered.contains(a)));
    return ordered;
  }

  /// The address [origin] sees first, or null when nothing decides it (the
  /// list then falls to keychain order). Site active key → global preferred
  /// key, each only if the site holds it. [granted] defaults to the site's
  /// current grants; pass it when already in hand. Touches nothing — safe for
  /// chrome that only wants to show which key a page is using.
  Future<String?> activeAccount(Uri origin, [Iterable<String>? granted]) async {
    final set = (granted ?? await _rawGrants(origin))
        .map((a) => a.toLowerCase())
        .toSet();
    if (set.isEmpty) return null;
    if (set.length == 1) return set.first;
    final active = (await grants.activeKeyFor(
      origin: originKey(origin),
      session: sessionAddress,
    ))
        ?.toLowerCase();
    if (active != null && set.contains(active)) return active;
    final preferred = (await wallet.preferredAddress())?.toLowerCase();
    if (preferred != null && set.contains(preferred)) return preferred;
    return null;
  }

  // -- the door -------------------------------------------------------------

  /// `eth_requestAccounts` -- THE DOOR.
  ///
  /// Already connected -> return the set silently, per EIP-1193. Not connected
  /// -> the picker. Refused -> 4001.
  ///
  /// A dApp that wants the picker anyway calls `wallet_requestPermissions`,
  /// which is [requestPermissions] and always prompts. That escape hatch is
  /// the reason this one may short-circuit at all.
  Future<List<String>> requestAccounts(Uri? origin) async {
    _requireOrigin(origin);
    final existing = await _rawGrants(origin!);
    if (existing.isNotEmpty) {
      log?.call('[web3] door: already granted (${existing.length} key(s))');
      return grantedAccounts(origin);
    }
    return requestPermissions(origin);
  }

  /// `wallet_requestPermissions` (EIP-2255) and the indicator tap.
  ///
  /// **Always opens the picker**, even when a grant exists -- that is what the
  /// method is FOR: the standard way a dApp asks the user to re-choose
  /// accounts. Routing it into [requestAccounts] made it inherit that method's
  /// already-granted short-circuit, which closed the only standard escape from
  /// a wrong selection.
  ///
  /// [requested] pre-checks a key the site named but does not hold yet.
  Future<List<String>> requestPermissions(
    Uri? origin, {
    String? requested,
  }) async {
    _requireOrigin(origin);

    final keys = await wallet.availableKeys();
    if (keys.isEmpty) {
      // Nothing we could hand over even if the user said yes: fail closed
      // rather than raising a sheet with no rows.
      throw const Web3Error(4100, 'No wallet available for this view.');
    }

    final already = (await _rawGrants(origin!)).toSet();
    final approved = await consent.requestConnect(ConnectRequest(
      origin: origin,
      keys: keys,
      alreadyGranted: already,
      preferred: await wallet.preferredAddress(),
      requested: requested?.toLowerCase(),
      activeKey: await grants.activeKeyFor(
        origin: originKey(origin),
        session: sessionAddress,
      ),
    ));

    // `null` is refusal; an EMPTY SET is the disconnect gesture and a perfectly
    // valid answer. The two must not collapse into one.
    if (approved == null) throw const Web3Error.rejected();

    return setGrants(origin, approved.visible, activeKey: approved.activeKey);
  }

  /// Apply a picker result: grant what is new, revoke what was unchecked, tell
  /// the page, report the connection.
  ///
  /// The single write path, so the four things that must happen together
  /// cannot drift apart -- store, live `selectedAddress` (for a dApp that
  /// *reads*), `accountsChanged` (for one that *listens*), and the host's
  /// indicator.
  ///
  /// **Uncheck-all is a disconnect**: rows deleted, `accountsChanged []`, icon
  /// gone. There is no separate "revoke" verb, because a picker that can
  /// express the empty set already is one.
  ///
  /// [activeKey] is the picker's per-site choice for `accounts[0]`; null
  /// clears any previous choice (the global preferred key orders the site
  /// again). A choice naming a key outside [approved] is ignored — the store
  /// keeps the flag on the grant row, so it cannot be represented anyway.
  Future<List<String>> setGrants(
    Uri origin,
    Set<String> approved, {
    String? activeKey,
  }) async {
    final key = originKey(origin);
    final want = approved.map((a) => a.toLowerCase()).toSet();
    final have = (await _rawGrants(origin)).toSet();

    // Labels are display-only, resolved from what we hold. A key we do not
    // hold cannot be granted at all -- the picker's rows come from
    // [WalletBinding.availableKeys], so this only bites a malformed caller.
    final byAddress = {
      for (final k in await wallet.availableKeys()) k.address: k,
    };

    for (final eoa in want.difference(have)) {
      final k = byAddress[eoa];
      if (k == null) {
        log?.call('[web3] refusing to grant unheld key $eoa');
        continue;
      }
      await grants.grantSite(
        origin: key,
        session: sessionAddress,
        eoa: eoa,
        keyLabel: k.label,
      );
    }
    for (final eoa in have.difference(want)) {
      await grants.revokeSite(origin: key, session: sessionAddress, eoa: eoa);
    }

    final active = activeKey?.toLowerCase();
    if (active != null && want.contains(active)) {
      await grants.setActiveKey(origin: key, session: sessionAddress, eoa: active);
    } else {
      await grants.clearActiveKey(origin: key, session: sessionAddress);
    }

    final ordered = await orderAccounts(origin, await _rawGrants(origin));
    await channel.setLiveAccount(ordered.isEmpty ? null : ordered.first);
    await channel.emit(Web3Events.accountsChanged, ordered);
    onConnectionChanged?.call(ordered.isNotEmpty);
    onActiveAccountChanged?.call(ordered.isEmpty ? null : ordered.first);
    log?.call('[web3] grants for $key -> ${ordered.length} key(s)');
    return ordered;
  }

  // -- gates ----------------------------------------------------------------

  /// Gate a key-using method on the key it actually names.
  ///
  /// Runs BEFORE the handler, so a signature sheet can never be summoned
  /// without a grant for the very key that would sign. Three outcomes:
  ///
  /// * **granted** -> proceed;
  /// * **ours, ungranted** -> raise the picker with it pre-checked, then
  ///   proceed if the user approved it. A deliberate divergence from
  ///   EIP-1193's flat 4100: the security property holds (approve the connect,
  ///   then approve the signature) and answering 4100 for a key we HOLD is a
  ///   dead end the user cannot escape;
  /// * **not ours at all** -> 4100, because no amount of consent produces a
  ///   key we do not have.
  Future<void> requireGrantFor(Uri? origin, String address) async {
    _requireOrigin(origin);
    if (address.isEmpty) {
      throw const Web3Error(4100, 'No address named for this request.');
    }
    if (await hasGrantFor(origin, address)) return;

    final eoa = address.toLowerCase();
    final keys = await wallet.availableKeys();
    if (!keys.any((k) => k.address == eoa)) {
      throw Web3Error(4100, 'This wallet does not hold $address.');
    }

    log?.call('[web3] $eoa is ours but ungranted -> asking');
    final granted = await requestPermissions(origin, requested: eoa);
    if (!granted.contains(eoa)) {
      // The sheet opened and the user left it out. That is a refusal of THIS
      // request, not an authorisation failure -- 4001, the code dApps
      // special-case as "the user said no".
      throw const Web3Error.rejected();
    }
  }

  /// Re-evaluate the running page after grants changed outside the provider
  /// (the indicator's picker, a revoke in the keychain).
  ///
  /// What matters is not which key is selected -- selection grants nothing --
  /// but which keys this origin holds.
  Future<void> refresh(Uri? origin) async {
    final ordered = origin == null
        ? const <String>[]
        : await orderAccounts(origin, await _rawGrants(origin));
    await channel.setLiveAccount(ordered.isEmpty ? null : ordered.first);
    await channel.emit(Web3Events.accountsChanged, ordered);
    onConnectionChanged?.call(ordered.isNotEmpty);
    onActiveAccountChanged?.call(ordered.isEmpty ? null : ordered.first);
    log?.call('[web3] refresh -> ${ordered.length} key(s)');
  }

  // -- helpers --------------------------------------------------------------

  Future<List<String>> _rawGrants(Uri origin) => grants.listGrants(
        origin: originKey(origin),
        session: sessionAddress,
      );

  void _requireOrigin(Uri? origin) {
    if (origin == null) {
      throw const Web3Error(4100, 'This page has no origin to grant.');
    }
  }

  /// The string a grant is recorded against: scheme + host + port, nothing
  /// else. Never a page title or anything else the page controls.
  ///
  /// **A non-default port is part of the identity** -- `https://x.com:8443` is
  /// a different site from `https://x.com` and gets its own grant. Dropping
  /// the port would make the two share one.
  ///
  /// **A DEFAULT port is elided**, which is the part that is easy to get
  /// wrong: `https://x.com:443` and `https://x.com` are the same origin, and a
  /// page can be loaded under either spelling. Keying on the raw port would
  /// split one site's grant in two depending on how its URL happened to be
  /// written, and the user would be re-prompted for a site they had already
  /// approved. Same rule as the URL spec's origin serialization.
  static String originKey(Uri url) {
    final defaultPort = url.scheme == 'http'
        ? 80
        : url.scheme == 'https'
            ? 443
            : null;
    final showPort = url.hasPort && url.port != defaultPort;
    return '${url.scheme}://${url.host}${showPort ? ':${url.port}' : ''}';
  }
}
