// The consent gate is the security boundary: it decides whether a page ever
// learns who the user is, and whether a signature sheet may be summoned at all.
// It is plain Dart over four seams rather than being welded to a widget, a
// keychain and a database, so every rule can be pinned with fakes.
//
// Permission is a per-site SET of keys, and the global pointer is only a
// preference deciding `accounts[0]`. Two tests check that switching the
// preferred key neither revokes nor grants access.
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';

import 'package:publicos_web3_bridge/src/connect_gate.dart';
import 'package:publicos_web3_bridge/src/wallet_binding.dart';
import 'package:publicos_web3_bridge/src/web3_channel.dart';
import 'package:publicos_web3_bridge/src/web3_consent.dart';
import 'package:publicos_web3_bridge/src/web3_error.dart';

const kSession = '0xaaa1';
const kAlice = '0xbbb2';
const kBob = '0xccc3';

class FakeWallet implements WalletBinding {
  List<WalletKey> keys;
  String? preferred;

  FakeWallet({List<WalletKey>? keys, this.preferred})
      : keys = keys ??
            [
              WalletKey(label: 'session', address: kSession),
              WalletKey(label: 'alice', address: kAlice),
              WalletKey(label: 'bob', address: kBob),
            ];

  @override
  Future<List<WalletKey>> availableKeys() async => keys;

  @override
  Future<String?> preferredAddress() async => preferred;

  @override
  Future<EthPrivateKey?> signingKeyFor(String address) async => null;
}

class FakeGrants implements GrantStore {
  final rows = <String>{};
  final touched = <String>[];
  int grantCalls = 0;
  int revokeCalls = 0;

  String _k(String o, String c, String e) => '$o|$c|$e';

  @override
  Future<bool> hasGrant({
    required String origin,
    required String session,
    required String eoa,
  }) async =>
      rows.contains(_k(origin, session, eoa.toLowerCase()));

  @override
  Future<List<String>> listGrants({
    required String origin,
    required String session,
  }) async =>
      rows
          .where((r) => r.startsWith('$origin|$session|'))
          .map((r) => r.split('|').last)
          .toList();

  @override
  Future<void> grantSite({
    required String origin,
    required String session,
    required String eoa,
    String? keyLabel,
  }) async {
    grantCalls++;
    rows.add(_k(origin, session, eoa.toLowerCase()));
  }

  @override
  Future<void> revokeSite({
    required String origin,
    required String session,
    required String eoa,
  }) async {
    revokeCalls++;
    rows.remove(_k(origin, session, eoa.toLowerCase()));
  }

  @override
  Future<void> touchGrant({
    required String origin,
    required String session,
    required String eoa,
  }) async =>
      touched.add(_k(origin, session, eoa.toLowerCase()));

  /// origin|session -> eoa. Set only when the row exists, like the real store.
  final active = <String, String>{};

  @override
  Future<String?> activeKeyFor({
    required String origin,
    required String session,
  }) async =>
      active['$origin|$session'];

  @override
  Future<void> setActiveKey({
    required String origin,
    required String session,
    required String eoa,
  }) async {
    if (rows.contains(_k(origin, session, eoa.toLowerCase()))) {
      active['$origin|$session'] = eoa.toLowerCase();
    }
  }

  @override
  Future<void> clearActiveKey({
    required String origin,
    required String session,
  }) async =>
      active.remove('$origin|$session');
}

class FakeConsent implements Web3Consent {
  /// What the picker answers. `null` = refusal; an empty set = disconnect.
  Set<String>? answer;

  /// The picker's per-site active choice, if any.
  String? activeKey;
  int connectAsks = 0;
  final seen = <ConnectRequest>[];

  FakeConsent(this.answer, {this.activeKey});

  @override
  Future<ConnectDecision?> requestConnect(ConnectRequest r) async {
    connectAsks++;
    seen.add(r);
    final a = answer;
    if (a == null) return null;
    return ConnectDecision(visible: a, activeKey: activeKey);
  }

  @override
  Future<bool> requestSignature(SignatureRequest r) async => true;
}

class RecordingChannel implements Web3Channel {
  final emitted = <String, Object?>{};
  final live = <String?>[];
  @override
  Future<void> emit(String event, Object? payload) async =>
      emitted[event] = payload;
  @override
  Future<void> setLiveAccount(String? address) async => live.add(address);
  @override
  Future<void> resolve(int id, Object? result) async {}
  @override
  Future<void> reject(int id, int code, String message) async {}
}

void main() {
  late FakeWallet wallet;
  late FakeGrants grants;
  late FakeConsent consent;
  late RecordingChannel channel;
  late List<bool> connections;

  final origin = Uri.parse('https://dapp.example/app?x=1#frag');

  ConnectGate build({
    Set<String>? approves = const {kSession},
    String? preferred,
    String? activeKey,
  }) {
    wallet = FakeWallet(preferred: preferred);
    grants = FakeGrants();
    consent = FakeConsent(approves, activeKey: activeKey);
    channel = RecordingChannel();
    connections = [];
    return ConnectGate(
      wallet: wallet,
      grants: grants,
      consent: consent,
      channel: channel,
      sessionAddress: '0xclient',
      onConnectionChanged: connections.add,
    );
  }

  group('originKey', () {
    test('is scheme + host + port only - never path, query or fragment', () {
      expect(ConnectGate.originKey(origin), 'https://dapp.example');
    });

    test('a NON-default port is part of the identity', () {
      // https://x:8443 is a different site from https://x and gets its own
      // grant. Dropping the port would make the two share one.
      expect(
        ConnectGate.originKey(Uri.parse('https://dapp.example:8443/x')),
        'https://dapp.example:8443',
      );
      expect(
        ConnectGate.originKey(Uri.parse('http://localhost:3000/x')),
        'http://localhost:3000',
      );
    });

    test('a DEFAULT port is elided - the same site written two ways', () {
      // A page can be loaded as either spelling. Keying on the raw port would
      // split one site's grant in two and re-prompt a user who had already
      // approved it.
      expect(
        ConnectGate.originKey(Uri.parse('https://dapp.example:443/x')),
        ConnectGate.originKey(Uri.parse('https://dapp.example/x')),
      );
      expect(
        ConnectGate.originKey(Uri.parse('http://dapp.example:80/x')),
        ConnectGate.originKey(Uri.parse('http://dapp.example/x')),
      );
    });

    test('http and https are different origins on the same host', () {
      expect(
        ConnectGate.originKey(Uri.parse('http://dapp.example/x')),
        isNot(ConnectGate.originKey(Uri.parse('https://dapp.example/x'))),
      );
    });
  });

  group('the passive read never prompts', () {
    test('eth_accounts is empty before a grant, and asks nobody', () async {
      final g = build();
      expect(await g.grantedAccounts(origin), isEmpty);
      expect(consent.connectAsks, 0,
          reason: 'a passive read must never raise a sheet');
    });
  });

  group('the gate is per key', () {
    test('requireGrantFor throws 4100 for an address we do not hold', () async {
      final g = build();
      expect(
        () => g.requireGrantFor(origin, '0xstranger'),
        throwsA(isA<Web3Error>().having((e) => e.code, 'code', 4100)),
      );
      expect(consent.connectAsks, 0,
          reason: 'no consent can produce a key we do not have');
    });

    test('requireGrantFor passes for a granted key', () async {
      final g = build();
      await g.requestAccounts(origin);
      await g.requireGrantFor(origin, kSession); // must not throw
    });

    test('a key we HOLD but have not granted raises the picker, then proceeds',
        () async {
      // The deliberate divergence from EIP-1193's flat 4100: answering "no" to
      // a key we actually have is a dead end the user cannot escape.
      final g = build();
      await g.requestAccounts(origin);
      consent.answer = {kSession, kAlice};

      await g.requireGrantFor(origin, kAlice); // must not throw
      expect(consent.connectAsks, 2);
      expect(consent.seen.last.requested, kAlice,
          reason: 'the sheet is told which key the site asked for');
      expect(await g.hasGrantFor(origin, kAlice), isTrue);
    });

    test('declining that picker is 4001, not 4100', () async {
      final g = build();
      await g.requestAccounts(origin);
      consent.answer = {kSession}; // user left alice out

      expect(
        () => g.requireGrantFor(origin, kAlice),
        throwsA(isA<Web3Error>().having((e) => e.code, 'code', 4001)),
      );
    });

    test('a null origin is denied, never granted', () async {
      final g = build();
      expect(await g.hasAnyGrant(null), isFalse);
      expect(await g.grantedAccounts(null), isEmpty);
    });

    test('no keys at all is denied - fails closed', () async {
      final g = build();
      wallet.keys = const [];
      expect(
        () => g.requestAccounts(origin),
        throwsA(isA<Web3Error>().having((e) => e.code, 'code', 4100)),
      );
      expect(consent.connectAsks, 0);
    });
  });

  group('the door', () {
    test('approval stores the grant AND makes reading and listening dApps honest',
        () async {
      final g = build();
      final accounts = await g.requestAccounts(origin);

      expect(accounts, [kSession]);
      expect(grants.grantCalls, 1);
      // All four legs, because a dApp may use any of them.
      expect(channel.live, [kSession],
          reason: 'reading dApps read selectedAddress');
      expect(channel.emitted[Web3Events.accountsChanged], [kSession],
          reason: 'listening dApps subscribe to accountsChanged');
      expect(connections, [true], reason: 'the host lights its indicator');
    });

    test('several keys can be approved at once - permission IS a set', () async {
      final g = build(approves: {kSession, kAlice, kBob});
      final accounts = await g.requestAccounts(origin);

      expect(accounts.toSet(), {kSession, kAlice, kBob});
      expect(grants.grantCalls, 3);
      expect(await g.hasGrantFor(origin, kAlice), isTrue);
      expect(await g.hasGrantFor(origin, kBob), isTrue);
    });

    test('refusal (null) throws 4001 and stores nothing', () async {
      final g = build(approves: null);
      expect(
        () => g.requestAccounts(origin),
        throwsA(isA<Web3Error>().having((e) => e.code, 'code', 4001)),
      );
      expect(grants.grantCalls, 0);
      expect(channel.live, isEmpty);
    });

    test('an EMPTY SET is not refusal - it is a disconnect', () async {
      final g = build(approves: {kSession, kAlice});
      await g.requestAccounts(origin);

      consent.answer = const {};
      final left = await g.requestPermissions(origin);

      expect(left, isEmpty);
      expect(grants.revokeCalls, 2, reason: 'both rows dropped');
      expect(channel.live.last, isNull, reason: 'selectedAddress cleared');
      expect(channel.emitted[Web3Events.accountsChanged], isEmpty);
      expect(connections.last, isFalse, reason: 'the indicator goes out');
    });

    test('a returning site is NOT re-prompted by eth_requestAccounts', () async {
      final g = build();
      await g.requestAccounts(origin);
      expect(consent.connectAsks, 1);

      await g.requestAccounts(origin);
      expect(consent.connectAsks, 1, reason: 'second visit must be silent');
      expect(grants.grantCalls, 1,
          reason: 'and must not double-write the grant');
    });

    test('wallet_requestPermissions ALWAYS prompts, even when granted', () async {
      // EIP-2255's whole purpose, and the escape hatch: routing it into
      // requestAccounts would inherit the short-circuit above.
      final g = build();
      await g.requestAccounts(origin);
      expect(consent.connectAsks, 1);

      await g.requestPermissions(origin);
      expect(consent.connectAsks, 2);
    });

    test('the picker is told what the site already holds', () async {
      final g = build(approves: {kSession, kAlice});
      await g.requestAccounts(origin);

      await g.requestPermissions(origin);
      expect(consent.seen.last.alreadyGranted, {kSession, kAlice},
          reason: 'the boxes open already checked');
    });

    test('re-picking applies the DIFFERENCE, both directions', () async {
      final g = build(approves: {kSession, kAlice});
      await g.requestAccounts(origin);
      grants.grantCalls = 0;

      consent.answer = {kAlice, kBob}; // drop session, add bob
      final now = await g.requestPermissions(origin);

      expect(now.toSet(), {kAlice, kBob});
      expect(grants.grantCalls, 1, reason: 'only bob is new');
      expect(grants.revokeCalls, 1, reason: 'only session was removed');
    });

    test('a key we do not hold cannot be granted, even if the sheet says so',
        () async {
      final g = build(approves: {kSession, '0xstranger'});
      final accounts = await g.requestAccounts(origin);
      expect(accounts, [kSession]);
      expect(await g.hasGrantFor(origin, '0xstranger'), isFalse);
    });
  });

  group('accounts[0] ordering', () {
    test('the preferred key comes first when this site holds it', () async {
      final g = build(approves: {kAlice, kBob}, preferred: kBob);
      final accounts = await g.requestAccounts(origin);
      expect(accounts.first, kBob);
    });

    test('a preference this site was NOT given is simply ignored', () async {
      // The pointer is ordering, not permission.
      final g = build(approves: {kAlice, kBob}, preferred: kSession);
      final accounts = await g.requestAccounts(origin);
      expect(accounts.contains(kSession), isFalse,
          reason: 'a preference grants nothing');
      expect(accounts.first, kAlice, reason: 'falls back to keychain order');
    });

    test('otherwise it is keychain order - session key first', () async {
      final g = build(approves: {kBob, kSession, kAlice});
      final accounts = await g.requestAccounts(origin);
      expect(accounts, [kSession, kAlice, kBob]);
    });

    test('the site ACTIVE key beats the global preferred key', () async {
      // The active key is a per-site choice; the global one is only a
      // fallback.
      final g = build(approves: {kAlice, kBob}, preferred: kBob, activeKey: kAlice);
      final accounts = await g.requestAccounts(origin);
      expect(accounts.first, kAlice);
      expect(grants.active.values, [kAlice]);
      expect(await g.activeAccount(origin), kAlice);
    });

    test('an active key outside the visible set is ignored, never stored', () async {
      final g = build(approves: {kAlice, kBob}, preferred: kBob, activeKey: kSession);
      final accounts = await g.requestAccounts(origin);
      expect(grants.active, isEmpty, reason: 'the flag lives on a grant row');
      expect(accounts.first, kBob, reason: 'falls back to the global preferred key');
    });

    test('revoking the active key drops the choice with the grant', () async {
      final g = build(approves: {kAlice, kBob}, preferred: kBob, activeKey: kAlice);
      await g.requestAccounts(origin);
      // Re-pick without alice: the store deletes her row, and the gate clears
      // a choice that no longer points inside the set.
      consent.answer = {kBob};
      consent.activeKey = kAlice;
      final accounts = await g.requestPermissions(origin);
      expect(accounts, [kBob]);
      expect(grants.active, isEmpty);
    });

    test('a null choice clears a previous one - the site follows the globe again',
        () async {
      final g = build(approves: {kAlice, kBob}, preferred: kBob, activeKey: kAlice);
      expect((await g.requestAccounts(origin)).first, kAlice);
      consent.activeKey = null;
      expect((await g.requestPermissions(origin)).first, kBob);
      expect(grants.active, isEmpty);
    });

    test('the picker is told the site\'s current active key', () async {
      final g = build(approves: {kAlice, kBob}, activeKey: kAlice);
      await g.requestAccounts(origin);
      await g.requestPermissions(origin);
      expect(consent.seen.last.activeKey, kAlice);
    });

    test('ordering is STABLE across reads - not lastUsedAt', () async {
      // grantedAccounts touches every row on every read, so lastUsedAt means
      // "when the site last looked" and is identical across a site's keys.
      // Ordering by it would make `accounts[0]` -- the identity most dApps
      // latch onto -- change across reloads.
      final g = build(approves: {kSession, kAlice, kBob});
      final first = await g.grantedAccounts(origin);
      final second = await g.grantedAccounts(origin);
      final third = await g.grantedAccounts(origin);
      expect(second, first);
      expect(third, first);
    });
  });

  group('the preferred key is NOT permission', () {
    // Switching the web-selected key must neither revoke nor grant a site's
    // access: the global pointer only orders keys, it never does permission's
    // job.
    test('switching the preferred key does NOT revoke a grant', () async {
      final g = build(approves: {kAlice});
      await g.requestAccounts(origin);
      expect(await g.hasGrantFor(origin, kAlice), isTrue);

      wallet.preferred = kBob; // user changed their preference
      expect(await g.hasGrantFor(origin, kAlice), isTrue,
          reason: 'permission is per site, not per pointer');
      expect(await g.hasAnyGrant(origin), isTrue);
    });

    test('and does NOT grant one either', () async {
      final g = build(approves: {kAlice});
      await g.requestAccounts(origin);

      wallet.preferred = kBob;
      expect(await g.hasGrantFor(origin, kBob), isFalse);
      expect(await g.grantedAccounts(origin), [kAlice]);
    });
  });

  group('refresh on a live page', () {
    test('a still-granted site re-announces its set', () async {
      final g = build(approves: {kSession, kAlice});
      await g.requestAccounts(origin);
      channel.live.clear();

      await g.refresh(origin);
      expect(channel.live.single, kSession);
      expect(
        (channel.emitted[Web3Events.accountsChanged] as List).toSet(),
        {kSession, kAlice},
      );
      expect(connections.last, isTrue);
    });

    test('a site whose grants were all revoked is told it is out', () async {
      final g = build();
      await g.requestAccounts(origin);
      grants.rows.clear(); // revoked from the keychain, outside the provider

      await g.refresh(origin);
      expect(channel.live.last, isNull, reason: 'selectedAddress cleared');
      expect(channel.emitted[Web3Events.accountsChanged], isEmpty,
          reason: 'accountsChanged carries [] when disconnected');
      expect(connections.last, isFalse, reason: 'the indicator hides');
    });
  });
}
