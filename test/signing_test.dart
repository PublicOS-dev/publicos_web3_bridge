// SCOPE NOTE. The EIP-191 procedure itself is web3dart's
// (`signPersonalMessageToUint8List`), not ours -- the move deliberately
// deleted the client's hand-rolled prefix/keccak/v-normalisation. So these
// tests cover what this package actually wrote: how a dApp's message is
// decoded, the param order of the two methods that reach the signer, and the
// shape of what comes back. Testing secp256k1 here would be testing a
// dependency.
//
// Signature validity end-to-end is proven where it matters: real dApps verify
// these signatures in the wild, and the mobile client has been shipping this
// exact output.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';

import 'package:publicos_web3_bridge/src/signing.dart';

void main() {
  // Deterministic test key. Never used anywhere real.
  final key = EthPrivateKey.fromHex(
    '4646464646464646464646464646464646464646464646464646464646464646',
  );

  group('signature shape', () {
    for (final message in [
      'hello',
      '',
      'Sign in to PublicOS\nNonce: 12345',
      'acentos y otros multi-byte',
      '0xdeadbeef',
    ]) {
      final label = message.isEmpty ? '(empty)' : message.split('\n').first;
      test('65 bytes for $label', () {
        final sig = signPersonalMessage(message, key);
        expect(sig.startsWith('0x'), isTrue);
        expect(sig.length, 132, reason: '0x + r(64) + s(64) + v(2)');
        expect(RegExp(r'^0x[0-9a-f]+$').hasMatch(sig), isTrue,
            reason: 'lowercase hex, no stray characters');
      });
    }

    test('v is 27 or 28, never a raw 0/1 recovery id', () {
      // A raw recovery id produces signatures that verify nowhere.
      for (final m in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        final v =
            int.parse(signPersonalMessage(m, key).substring(130), radix: 16);
        expect(v, anyOf(27, 28));
      }
    });

    test('is deterministic for the same key and message', () {
      expect(signPersonalMessage('same', key), signPersonalMessage('same', key));
    });

    test('differs for different messages', () {
      expect(
          signPersonalMessage('a', key), isNot(signPersonalMessage('b', key)));
    });
  });

  group('message decoding - ours, and easy to get wrong', () {
    test('0x-prefixed is treated as hex', () {
      expect(decodeMessage('0x48656c6c6f'), utf8.encode('Hello'));
    });

    test('everything else is treated as UTF-8 text', () {
      expect(decodeMessage('Hello'), utf8.encode('Hello'));
    });

    test('multi-byte text decodes to BYTES, not characters', () {
      // The EIP-191 prefix embeds a byte length. Counting characters here
      // produces a signature nobody can verify.
      expect(decodeMessage('ñ').length, greaterThan(1));
      expect(decodeMessage('ñ'), utf8.encode('ñ'));
      expect(decodeMessage('ñ').length, 2);
    });

    test('a hex message and its text equivalent sign identically', () {
      // Same bytes in, same signature out - the whole point of the 0x
      // convention.
      expect(
        signPersonalMessage('0x48656c6c6f', key),
        signPersonalMessage('Hello', key),
      );
    });
  });

  group('param order - the EIP quirk', () {
    test('personal_sign is [message, address]', () {
      final p = personalSignParams(['the message', '0xaddr']);
      expect(p.message, 'the message');
      expect(p.address, '0xaddr');
    });

    test('eth_sign is [address, message] - REVERSED', () {
      final p = ethSignParams(['0xaddr', 'the message']);
      expect(p.message, 'the message');
      expect(p.address, '0xaddr');
    });

    test('the two orders really do disagree', () {
      // If someone "simplifies" these into one helper, this fails.
      final args = ['0xaddr', 'the message'];
      expect(
        personalSignParams(args).message,
        isNot(ethSignParams(args).message),
      );
    });

    test('both reject short param lists instead of signing garbage', () {
      expect(() => personalSignParams(['only one']), throwsFormatException);
      expect(() => ethSignParams(null), throwsFormatException);
    });
  });
}
