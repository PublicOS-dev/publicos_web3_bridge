// The dispatcher is where the security model is enforced, so this is the file
// that matters most. The load-bearing assertions are the negative ones: that a
// signature sheet CANNOT be summoned without a grant, that an out-of-scope page
// gets nothing, and that every single request is answered.
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';

import 'package:publicos_web3_bridge/src/chain_registry.dart';
import 'package:publicos_web3_bridge/src/connect_gate.dart';
import 'package:publicos_web3_bridge/src/transactions.dart';
import 'package:publicos_web3_bridge/src/wallet_binding.dart';
import 'package:publicos_web3_bridge/src/web3_channel.dart';
import 'package:publicos_web3_bridge/src/web3_consent.dart';
import 'package:publicos_web3_bridge/src/web3_dispatcher.dart';
import 'package:publicos_web3_bridge/src/signing.dart';
import 'package:publicos_web3_bridge/src/web3_rpc.dart';
import 'package:publicos_web3_bridge/src/web_view_host.dart';

/// Two real keys, because the dispatcher now picks BETWEEN them by address --
/// a fake that returns one key for every question could not tell the defect
/// under test (signing with someone else's key) from correct behaviour.
final aliceKey = EthPrivateKey.fromHex(
  '4646464646464646464646464646464646464646464646464646464646464646',
);
final bobKey = EthPrivateKey.fromHex(
  '1111111111111111111111111111111111111111111111111111111111111111',
);
final alice = aliceKey.address.eip55With0x.toLowerCase();
final bob = bobKey.address.eip55With0x.toLowerCase();
const stranger = '0x00000000000000000000000000000000deadbeef';

class FakeWallet implements WalletBinding {
  @override
  Future<List<WalletKey>> availableKeys() async => [
        WalletKey(label: 'alice', address: alice),
        WalletKey(label: 'bob', address: bob),
      ];

  @override
  Future<String?> preferredAddress() async => alice;

  /// EXACT match or null -- the rule the whole change turns on.
  @override
  Future<EthPrivateKey?> signingKeyFor(String address) async {
    final a = address.toLowerCase();
    if (a == alice) return aliceKey;
    if (a == bob) return bobKey;
    return null;
  }
}

class FakeGrants implements GrantStore {
  final _g = <String>{};
  @override
  Future<bool> hasGrant({required String origin, required String session, required String eoa}) async =>
      _g.contains('$origin|${eoa.toLowerCase()}');
  @override
  Future<List<String>> listGrants({required String origin, required String session}) async =>
      _g.where((r) => r.startsWith('$origin|')).map((r) => r.split('|').last).toList();
  @override
  Future<void> grantSite({required String origin, required String session, required String eoa, String? keyLabel}) async =>
      _g.add('$origin|${eoa.toLowerCase()}');
  @override
  Future<void> revokeSite({required String origin, required String session, required String eoa}) async =>
      _g.remove('$origin|${eoa.toLowerCase()}');
  @override
  Future<void> touchGrant({required String origin, required String session, required String eoa}) async {}
  final _active = <String, String>{};
  @override
  Future<String?> activeKeyFor({required String origin, required String session}) async => _active[origin];
  @override
  Future<void> setActiveKey({required String origin, required String session, required String eoa}) async {
    if (_g.contains('$origin|${eoa.toLowerCase()}')) _active[origin] = eoa.toLowerCase();
  }
  @override
  Future<void> clearActiveKey({required String origin, required String session}) async => _active.remove(origin);
}

class SpyConsent implements Web3Consent {
  bool approve;
  int connectAsks = 0;
  final connectReqs = <ConnectRequest>[];
  final signAsks = <SignatureRequest>[];

  /// What the picker returns when [approve]. Defaults to alice alone, so the
  /// existing single-key expectations keep meaning what they meant.
  Set<String>? approves;

  SpyConsent(this.approve);

  @override
  Future<ConnectDecision?> requestConnect(ConnectRequest r) async {
    connectAsks++;
    connectReqs.add(r);
    if (!approve) return null;
    return ConnectDecision(visible: approves ?? {alice});
  }
  @override
  Future<bool> requestSignature(SignatureRequest r) async {
    signAsks.add(r);
    return approve;
  }
}

class SpyChannel implements Web3Channel {
  final resolved = <int, Object?>{};
  final rejected = <int, (int, String)>{};
  @override
  Future<void> resolve(int id, Object? result) async => resolved[id] = result;
  @override
  Future<void> reject(int id, int code, String message) async =>
      rejected[id] = (code, message);
  @override
  Future<void> emit(String event, Object? payload) async {}
  @override
  Future<void> setLiveAccount(String? address) async {}
}

class SpyRpc implements Web3Rpc {
  final calls = <String>[];
  @override
  Future<Object?> call(String method, List<dynamic>? params) async {
    calls.add(method);
    return '0xrpc';
  }
}

class SpyExecutor implements TransactionExecutor {
  final sent = <Map<String, dynamic>>[];
  final signedOnly = <Map<String, dynamic>>[];
  @override
  Future<String> send(Map<String, dynamic> tx, EthPrivateKey key) async {
    sent.add(tx);
    return '0xhash';
  }
  @override
  Future<String> signOnly(Map<String, dynamic> tx, EthPrivateKey key) async {
    signedOnly.add(tx);
    return '0xsigned';
  }
}

void main() {
  late SpyConsent consent;
  late SpyChannel channel;
  late SpyRpc rpc;
  late SpyExecutor exec;
  late FakeGrants grants;
  late Web3Dispatcher d;
  Uri origin = Uri.parse('https://dapp.example/app');

  Web3Dispatcher build({WebScope scope = WebScope.unrestricted, bool approve = true}) {
    consent = SpyConsent(approve);
    channel = SpyChannel();
    rpc = SpyRpc();
    exec = SpyExecutor();
    grants = FakeGrants();
    final wallet = FakeWallet();
    final chains = ChainRegistry();
    final gate = ConnectGate(
      wallet: wallet,
      grants: grants,
      consent: consent,
      channel: channel,
      sessionAddress: '0xclient',
    );
    return Web3Dispatcher(
      gate: gate,
      wallet: wallet,
      consent: consent,
      channel: channel,
      chains: chains,
      rpc: rpc,
      transactions: exec,
      currentOrigin: () => origin,
      scope: scope,
    );
  }

  Future<void> req(int id, String method, [List<dynamic>? params]) =>
      d.handle('{"id":$id,"method":"$method","params":${params == null ? 'null' : _json(params)}}');

  setUp(() {
    origin = Uri.parse('https://dapp.example/app');
    d = build();
  });

  group('every request is answered', () {
    // An unanswered request leaves the page's promise pending forever.
    test('unsupported method rejects with 4200, not a success string', () async {
      await req(1, 'eth_coinbase');
      expect(channel.resolved, isEmpty);
      expect(channel.rejected[1]!.$1, 4200);
    });

    test('bad params reject with -32602 rather than hanging', () async {
      await grantIt(d);
      await req(2, 'personal_sign', ['only-one-arg']);
      expect(channel.rejected[2]!.$1, -32602);
    });

    test('a malformed message with no id is dropped, not crashed on', () async {
      await d.handle('not json at all');
      expect(channel.resolved, isEmpty);
      expect(channel.rejected, isEmpty);
    });
  });

  group('THE GATE - a sheet cannot be summoned without a grant', () {
    // The gate is PER KEY, so "no grant" splits in two. An address we do not
    // hold is a flat 4100; an address we DO hold raises the
    // connect picker first (see the group below). These use a stranger so the
    // assertion under test is the hard refusal.
    test('personal_sign for an unheld address rejects 4100 and shows NO sheet',
        () async {
      await req(1, 'personal_sign', ['hello', stranger]);
      expect(channel.rejected[1]!.$1, 4100);
      expect(consent.signAsks, isEmpty,
          reason: 'the whole point: no grant means no sheet, ever');
      expect(consent.connectAsks, 0,
          reason: 'no consent can produce a key we do not have');
    });

    test('eth_sign for an unheld address rejects 4100 and shows NO sheet',
        () async {
      await req(1, 'eth_sign', [stranger, 'hello']);
      expect(channel.rejected[1]!.$1, 4100);
      expect(consent.signAsks, isEmpty);
    });

    test('eth_signTypedData_v4 for an unheld address rejects 4100', () async {
      await req(1, 'eth_signTypedData_v4', [stranger, '{}']);
      expect(channel.rejected[1]!.$1, 4100);
      expect(consent.signAsks, isEmpty);
    });

    for (final m in ['eth_sendTransaction', 'eth_signTransaction']) {
      test('$m naming an unheld `from` rejects 4100 and shows NO sheet',
          () async {
        await req(1, m, [
          {'to': '0xdef', 'from': stranger}
        ]);
        expect(channel.rejected[1]!.$1, 4100);
        expect(consent.signAsks, isEmpty);
      });

      test('$m with NO `from` and no grant rejects 4100', () async {
        // Omitted `from` means "whoever you are" -> accounts[0]. With nothing
        // granted there is no honest identity to sign as, so it fails closed
        // rather than substituting one.
        await req(1, m, [
          {'to': '0xdef'}
        ]);
        expect(channel.rejected[1]!.$1, 4100);
        expect(consent.signAsks, isEmpty);
      });
    }
  });

  group('THE ADDRESS THE dApp NAMES IS THE ADDRESS THAT SIGNS', () {
    // The defect this change exists to close: the address was parsed, shown in
    // the sheet, then IGNORED -- the globally selected key signed instead, so
    // the signature did not recover to the address the dApp asked for. Zerion
    // rejected a SIWE login over exactly this.
    setUp(() async {
      consent.approves = {alice, bob};
      await grantIt(d);
    });

    test('personal_sign for bob recovers to BOB, not the preferred key',
        () async {
      await req(1, 'personal_sign', ['hello', bob]);
      final sig = channel.resolved[1] as String;
      expect(sig, isNot(signPersonalMessage('hello', aliceKey)),
          reason: 'alice is the PREFERRED key -- it must not be the signer');
      expect(sig, signPersonalMessage('hello', bobKey));
    });

    test('and for alice recovers to alice', () async {
      await req(1, 'personal_sign', ['hello', alice]);
      expect(channel.resolved[1], signPersonalMessage('hello', aliceKey));
    });

    test('the sheet is shown the SAME address that will sign', () async {
      await req(1, 'personal_sign', ['hello', bob]);
      expect(consent.signAsks.single.address, bob);
    });

    test('eth_sendTransaction honours a named `from`', () async {
      // `from` was never read AT ALL before this change -- transactionParams
      // parses to/value/data/gas and nothing else -- so the sheet showed the
      // globally selected address while the globally selected key signed.
      await req(1, 'eth_sendTransaction', [
        {'to': '0xdef', 'from': bob}
      ]);
      expect(consent.signAsks.single.address, bob);
      expect(exec.sent, hasLength(1));
    });

    test('an omitted `from` resolves to accounts[0]', () async {
      await req(1, 'eth_sendTransaction', [
        {'to': '0xdef'}
      ]);
      expect(consent.signAsks.single.address, alice,
          reason: 'alice is preferred and permitted, so it is accounts[0]');
    });
  });

  group('a key we HOLD but have not granted', () {
    // The deliberate divergence from EIP-1193's flat 4100: approve the connect,
    // then approve the signature. Answering 4100 for a key we have is a dead
    // end -- the dApp asked for something possible and there was no way to say
    // yes.
    setUp(() async {
      consent.approves = {alice};
      await grantIt(d); // alice only
    });

    test('raises the connect picker, then signs', () async {
      consent.approves = {alice, bob};
      await req(1, 'personal_sign', ['hello', bob]);

      expect(consent.connectAsks, 2, reason: 'the picker was raised');
      expect(consent.connectReqs.last.requested, bob,
          reason: 'and told which key the site asked for');
      expect(channel.resolved[1], signPersonalMessage('hello', bobKey));
    });

    test('leaving it unchecked is 4001, and nothing is signed', () async {
      consent.approves = {alice}; // user did not add bob
      await req(1, 'personal_sign', ['hello', bob]);

      expect(channel.rejected[1]!.$1, 4001);
      expect(consent.signAsks, isEmpty, reason: 'no signature sheet was shown');
    });
  });

  group('passive reads never prompt', () {
    test('eth_accounts is [] before a grant and asks nobody', () async {
      await req(1, 'eth_accounts');
      expect(channel.resolved[1], isEmpty);
      expect(consent.connectAsks, 0);
    });

    test('wallet_getPermissions is [] before a grant and asks nobody', () async {
      await req(1, 'wallet_getPermissions');
      expect(channel.resolved[1], isEmpty);
      expect(consent.connectAsks, 0);
    });

    test('chain info needs no grant at all', () async {
      await req(1, 'eth_chainId');
      await req(2, 'net_version');
      expect(channel.resolved[1], '0x1189');
      expect(channel.resolved[2], '4489');
    });
  });

  group('the door', () {
    test('eth_requestAccounts prompts, then returns the account', () async {
      await req(1, 'eth_requestAccounts');
      expect(consent.connectAsks, 1);
      expect(channel.resolved[1], [alice]);
    });

    test('a refused door rejects 4001', () async {
      d = build(approve: false);
      await req(1, 'eth_requestAccounts');
      expect(channel.rejected[1]!.$1, 4001);
    });

    test('wallet_requestPermissions ALWAYS prompts, even when connected',
        () async {
      // EIP-2255's entire purpose: the standard way a dApp asks the user to
      // re-choose accounts. Routing it into `requestAccounts` would inherit
      // that method's already-granted short-circuit, which closes the only
      // standard escape from a wrong selection.
      await req(1, 'eth_requestAccounts');
      expect(consent.connectAsks, 1);

      await req(2, 'wallet_requestPermissions');
      expect(consent.connectAsks, 2, reason: 'it must not short-circuit');
      final perms = channel.resolved[2] as List;
      expect(perms.first['parentCapability'], 'eth_accounts');
    });

    test('the permission carries the WHOLE set, not just the first key',
        () async {
      consent.approves = {alice, bob};
      await req(1, 'wallet_requestPermissions');
      final perms = channel.resolved[1] as List;
      final caveat = (perms.first['caveats'] as List).first;
      expect((caveat['value'] as List).toSet(), {alice, bob});
    });
  });

  group('signing, once granted', () {
    setUp(() async => grantIt(d));

    test('personal_sign shows a sheet and returns a signature', () async {
      await req(1, 'personal_sign', ['hello', alice]);
      expect(consent.signAsks.single.kind, SignatureKind.message);
      expect(consent.signAsks.single.display, 'hello');
      expect((channel.resolved[1] as String).length, 132);
    });

    test('eth_sign reads its params REVERSED from personal_sign', () async {
      await req(1, 'eth_sign', [alice, 'hello']);
      expect(consent.signAsks.single.display, 'hello',
          reason: 'address-first order must reach the signer correctly');
    });

    test('eth_sign is a DIFFERENT kind from personal_sign', () async {
      // It is the legacy blind-signing method; the sheet warns harder about
      // it. Collapsing the two kinds would silently drop that warning.
      await req(1, 'personal_sign', ['hello', alice]);
      await req(2, 'eth_sign', [alice, 'hello']);
      expect(consent.signAsks[0].kind, SignatureKind.message);
      expect(consent.signAsks[1].kind, SignatureKind.legacyEthSign);
    });

    test('a refused signature rejects 4001 and signs nothing', () async {
      // Granted first, THEN the user refuses the signature -- otherwise the
      // 4001 under test would be the connect refusal, not the signing one.
      consent.approve = false;
      await req(1, 'personal_sign', ['hello', alice]);
      expect(channel.rejected[1]!.$1, 4001);
      expect(consent.signAsks, hasLength(1), reason: 'the sheet WAS shown');
    });

    test('send and sign-only are DIFFERENT asks and different actions', () async {
      await req(1, 'eth_sendTransaction', [
        {'to': '0xdef', 'value': '0x1'}
      ]);
      expect(consent.signAsks.last.kind, SignatureKind.sendTransaction);
      expect(exec.sent, hasLength(1));
      expect(exec.signedOnly, isEmpty);
      expect(channel.resolved[1], '0xhash');

      await req(2, 'eth_signTransaction', [
        {'to': '0xdef'}
      ]);
      expect(consent.signAsks.last.kind, SignatureKind.transaction);
      expect(exec.signedOnly, hasLength(1));
      expect(channel.resolved[2], '0xsigned');
    });

    test('typed data is PARSED before the user is asked', () async {
      // Approving something we cannot faithfully sign is the worst outcome.
      await req(1, 'eth_signTypedData_v4', [alice, 'not valid json']);
      expect(consent.signAsks, isEmpty, reason: 'no sheet for an unparseable payload');
      expect(channel.rejected.containsKey(1), isTrue);
    });
  });

  group('read-only RPC', () {
    test('an allowlisted method is forwarded without a grant', () async {
      await req(1, 'eth_blockNumber');
      expect(rpc.calls, ['eth_blockNumber']);
      expect(channel.resolved[1], '0xrpc');
    });

    test('a NON-allowlisted method is refused, never forwarded', () async {
      await req(1, 'eth_sendRawTransaction', ['0xdeadbeef']);
      expect(rpc.calls, isEmpty, reason: 'silence means no');
      expect(channel.rejected[1]!.$1, 4200);
    });
  });

  group('scope - layer 2 of the safeguard', () {
    setUp(() {
      d = build(scope: WebScope.of(Uri.parse('https://dapp.example/app'), lockToPath: true));
    });

    test('in-scope pages work normally', () async {
      await req(1, 'eth_requestAccounts');
      expect(channel.resolved[1], [alice]);
    });

    test('an SPA that navigated out of scope loses the bridge', () async {
      // history.pushState fires no navigation event, so no engine hook can
      // catch this. Only the request-time check can.
      await req(1, 'eth_requestAccounts');
      origin = Uri.parse('https://dapp.example/somewhere-else');

      await req(2, 'personal_sign', ['hello', alice]);
      expect(channel.rejected[2]!.$1, 4100);
      expect(consent.signAsks, isEmpty);
    });

    test('a different origin gets an empty eth_accounts, not an error', () async {
      origin = Uri.parse('https://evil.example/app');
      await req(1, 'eth_accounts');
      expect(channel.resolved[1], isEmpty);
    });

    test('an unreadable origin is refused', () async {
      origin = Uri.parse('about:blank');
      await req(1, 'eth_requestAccounts');
      expect(channel.rejected[1]!.$1, 4100);
    });
  });

  group('chain switching', () {
    test('switching an unknown chain rejects 4902', () async {
      await req(1, 'wallet_switchEthereumChain', [
        {'chainId': '0xdead'}
      ]);
      expect(channel.rejected[1]!.$1, 4902);
    });

    test('switching a known chain succeeds and moves eth_chainId', () async {
      await req(1, 'wallet_switchEthereumChain', [
        {'chainId': '0x1'}
      ]);
      await req(2, 'eth_chainId');
      expect(channel.resolved[2], '0x1');
    });
  });
}

Future<void> grantIt(Web3Dispatcher d) async =>
    d.handle('{"id":900,"method":"eth_requestAccounts","params":null}');

String _json(List<dynamic> v) {
  String enc(dynamic x) {
    if (x is String) return '"$x"';
    if (x is Map) {
      return '{${x.entries.map((e) => '"${e.key}":${enc(e.value)}').join(',')}}';
    }
    if (x is List) return '[${x.map(enc).join(',')}]';
    return '$x';
  }
  return '[${v.map(enc).join(',')}]';
}
