import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/chain_registry.dart';
import 'package:publicos_web3_bridge/src/web3_error.dart';
import 'package:publicos_web3_bridge/src/web3_rpc.dart';

void main() {
  group('defaults', () {
    test('starts on PublicOS 4489', () {
      final c = ChainRegistry();
      expect(c.currentChainId, '0x1189');
      expect(c.currentRpcUrl, 'https://rpc.publicos.dev');
    });

    test('net_version is the decimal of the hex chain id', () {
      expect(ChainRegistry().networkVersion, '4489');
      expect(ChainRegistry(initialChainId: '0x1').networkVersion, '1');
      expect(ChainRegistry(initialChainId: '0x89').networkVersion, '137');
    });

    test('the registry is per-webview, not shared', () {
      final a = ChainRegistry();
      final b = ChainRegistry();
      a.switchChain('0x1');
      expect(a.currentChainId, '0x1');
      expect(b.currentChainId, '0x1189', reason: 'one page must not move another');
    });
  });

  group('switchChain', () {
    test('switching fires the event once and returns null', () {
      final seen = <String>[];
      final c = ChainRegistry(onChainChanged: seen.add);

      expect(c.switchChain('0x1'), isNull);
      expect(c.currentChainId, '0x1');
      expect(seen, ['0x1']);
    });

    test('switching to the CURRENT chain does not fire the event', () {
      // A dApp that re-asserts its chain on every page load would otherwise
      // spam chainChanged at listeners.
      final seen = <String>[];
      final c = ChainRegistry(onChainChanged: seen.add);
      expect(c.switchChain('0x1189'), isNull);
      expect(seen, isEmpty);
    });

    test('an unknown chain throws 4902, the code dApps branch on', () {
      // 4902 is their cue to try wallet_addEthereumChain. A generic error
      // just makes them give up.
      final c = ChainRegistry();
      expect(
        () => c.switchChain('0xdead'),
        throwsA(isA<Web3Error>().having((e) => e.code, 'code', 4902)),
      );
      expect(c.currentChainId, '0x1189', reason: 'a failed switch changes nothing');
    });
  });

  group('addChain is deliberately inert', () {
    test('reports success but registers NOTHING', () {
      // Honouring it would let a page point our eth_calls at a host it chose.
      final c = ChainRegistry();
      expect(
        c.addChain({
          'chainId': '0xdead',
          'rpcUrls': ['https://evil.example/rpc'],
        }),
        isNull,
      );
      expect(c.supports('0xdead'), isFalse);
      expect(c.rpcUrlFor('0xdead'), isNull);
      expect(
        () => c.switchChain('0xdead'),
        throwsA(isA<Web3Error>()),
        reason: 'and the follow-up switch still fails',
      );
    });

    test('still validates the request shape', () {
      final c = ChainRegistry();
      expect(() => c.addChain({'rpcUrls': ['x']}), throwsA(isA<Web3Error>()));
      expect(() => c.addChain({'chainId': '0x1'}), throwsA(isA<Web3Error>()));
      expect(() => c.addChain({'chainId': '0x1', 'rpcUrls': []}),
          throwsA(isA<Web3Error>()));
    });
  });

  group('the read-only allowlist', () {
    test('contains only read methods - nothing that signs or reveals', () {
      for (final m in readOnlyRpcMethods) {
        expect(
          m,
          isNot(anyOf(
            'eth_sendTransaction',
            'eth_signTransaction',
            'eth_sign',
            'personal_sign',
            'eth_accounts',
            'eth_requestAccounts',
            'wallet_requestPermissions',
          )),
          reason: '$m must never be forwardable',
        );
        expect(m.contains('sign'), isFalse, reason: '$m looks like a signing method');
      }
    });

    test('is an allowlist - an unlisted method is not forwardable', () {
      expect(readOnlyRpcMethods.contains('eth_sendRawTransaction'), isFalse);
      expect(readOnlyRpcMethods.contains('personal_unlockAccount'), isFalse);
      expect(readOnlyRpcMethods.contains('eth_coinbase'), isFalse);
    });

    test('covers what a dApp actually polls', () {
      for (final m in ['eth_call', 'eth_blockNumber', 'eth_getBalance', 'eth_estimateGas']) {
        expect(readOnlyRpcMethods, contains(m));
      }
    });
  });
}
