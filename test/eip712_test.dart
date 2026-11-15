// EIP-712 is the highest-risk thing in the bridge: a struct hash that is
// subtly wrong still produces a well-formed signature, it just covers
// something other than what the user was shown and what the dApp verifies.
//
// Three groups. The first pins spec-correct behaviour the encoder relies on.
// The second covers three ways an encoder can silently depart from the spec
// (D1-D3 in lib/src/eip712.dart): each test asserts the correct result and,
// where it applies, that the wrong output never appears. The third is the
// canonical example from the EIP-712 spec itself, the only vector in this file
// not derived from our own code.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/eip712.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final domainTypes = {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'version', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
    ],
  };

  group('spec-correct behaviour we depend on', () {
    test('keccak256 matches the known empty-input digest', () {
      expect(
        hex(keccak256(Uint8List(0))),
        'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470',
      );
    });

    test('encodeType renders a flat struct exactly per spec', () {
      expect(
        encodeType('EIP712Domain', domainTypes),
        'EIP712Domain(string name,string version,uint256 chainId)',
      );
    });

    test('string and bytes are hashed, not inlined', () {
      expect(encodeValue('string', 'abc', {}), keccak256(Uint8List.fromList(utf8.encode('abc'))));
      expect(encodeValue('bytes', '0xabcd', {}), keccak256(Uint8List.fromList([0xab, 0xcd])));
    });

    test('address is right-aligned in 32 bytes', () {
      final e = encodeValue('address', '0x${'11' * 20}', {});
      expect(e.length, 32);
      expect(hex(e), '${'00' * 12}${'11' * 20}');
    });

    test('uint256 is right-aligned big-endian', () {
      expect(hex(encodeValue('uint256', 1, {})), '${'00' * 31}01');
      expect(hex(encodeValue('uint256', '0xff', {})), '${'00' * 31}ff');
      expect(hex(encodeValue('uint256', '255', {})), '${'00' * 31}ff');
    });

    test('bool is right-aligned 0 or 1', () {
      expect(hex(encodeValue('bool', true, {})), '${'00' * 31}01');
      expect(hex(encodeValue('bool', false, {})), '00' * 32);
    });

    test('bytesN is LEFT-aligned - the opposite of the numeric types', () {
      final e = encodeValue('bytes4', '0xdeadbeef', {});
      expect(hex(e), 'deadbeef${'00' * 28}');
    });

    test('the digest envelope is 0x19 0x01 ++ domain ++ message', () {
      final types = {
        ...domainTypes,
        'Msg': [
          {'name': 'contents', 'type': 'string'}
        ],
      };
      final domain = {'name': 'PublicOS', 'version': '1', 'chainId': 4489};
      final message = {'contents': 'hello'};

      final expected = keccak256(Uint8List.fromList([
        0x19,
        0x01,
        ...hashStruct('EIP712Domain', domain, types),
        ...hashStruct('Msg', message, types),
      ]));

      expect(
        typedDataDigest(
          domain: domain,
          types: types,
          primaryType: 'Msg',
          message: message,
        ),
        expected,
      );
    });

    test('typed data is accepted as a JSON string or an object', () {
      const asString = '{"domain":{},"types":{},"primaryType":"X","message":{}}';
      expect(parseTypedData(asString)['primaryType'], 'X');
      expect(parseTypedData({'primaryType': 'X'})['primaryType'], 'X');
      expect(() => parseTypedData(42), throwsFormatException);
    });

    test('params are [address, typedData] - address first, like eth_sign', () {
      final p = signTypedDataParams(['0xaddr', {'primaryType': 'X'}]);
      expect(p.address, '0xaddr');
      expect((p.typedData as Map)['primaryType'], 'X');
    });
  });

  // ===========================================================================
  // The three spec traps D1-D3 (see lib/src/eip712.dart). Each test asserts
  // the spec-correct result and, where it applies, that the wrong output
  // never appears.
  // ===========================================================================
  group('FIXED deviations - inverted assertions', () {
    final nestedTypes = {
      'Mail': [
        {'name': 'from', 'type': 'Person'},
        {'name': 'contents', 'type': 'string'},
      ],
      'Person': [
        {'name': 'name', 'type': 'string'},
        {'name': 'wallet', 'type': 'address'},
      ],
    };

    test('was D1: referenced struct types ARE appended to encodeType', () {
      expect(
        encodeType('Mail', nestedTypes),
        'Mail(Person from,string contents)Person(string name,address wallet)',
      );
      expect(
        encodeType('Mail', nestedTypes),
        isNot('Mail(Person from,string contents)'),
        reason: 'the pre-fix output must never return',
      );
    });

    test('was D2: negative ints use twos complement, NOT their unsigned twin', () {
      expect(hex(encodeValue('int256', -1, {})), 'ff' * 32);
      expect(hex(encodeValue('int256', -2, {})), '${'ff' * 31}fe');

      // int256(-1) and uint256(255) must not encode alike.
      expect(
        encodeValue('int256', -1, {}),
        isNot(encodeValue('uint256', 255, {})),
        reason: 'the pre-fix collision must never return',
      );
    });

    test('was D2: every byte is in range - no negative values in the list', () {
      // A naive encoding leaves -1 in the List<int>, which wraps silently later.
      for (final v in [-1, -255, -256, -65536]) {
        final e = encodeValue('int256', v, {});
        expect(e.every((b) => b >= 0 && b <= 255), isTrue, reason: 'value $v');
      }
    });

    test('was D2: a negative value in an UNSIGNED field is refused', () {
      expect(() => encodeValue('uint256', -1, {}), throwsFormatException);
    });

    test('was D3: arrays hash their items - different arrays differ', () {
      final types = {
        'Person': [
          {'name': 'name', 'type': 'string'}
        ],
      };
      final alice = encodeValue('Person[]', [
        {'name': 'alice'}
      ], types);
      final bob = encodeValue('Person[]', [
        {'name': 'bob'}
      ], types);

      expect(alice, isNot(bob), reason: 'the pre-fix collision must never return');
      expect(hex(alice), isNot('00' * 32), reason: 'no longer 32 zero bytes');
      expect(alice.length, 32, reason: 'still a 32-byte keccak');
    });

    test('was D3: an array encodes as keccak of its items concatenated', () {
      final expected = keccak256(Uint8List.fromList([
        ...encodeValue('uint256', 1, {}),
        ...encodeValue('uint256', 2, {}),
      ]));
      expect(encodeValue('uint256[]', [1, 2], {}), expected);
    });

    test('was D3: order matters, and an empty array is not zero bytes', () {
      expect(
        encodeValue('uint256[]', [1, 2], {}),
        isNot(encodeValue('uint256[]', [2, 1], {})),
      );
      expect(hex(encodeValue('uint256[]', [], {})), hex(keccak256(Uint8List(0))));
    });

    test('was D3: fixed-length arrays enforce their length', () {
      expect(encodeValue('uint256[2]', [1, 2], {}).length, 32);
      expect(() => encodeValue('uint256[2]', [1], {}), throwsFormatException);
      expect(() => encodeValue('uint256[]', 'not a list', {}), throwsFormatException);
    });

    test('was D3: nested arrays recurse', () {
      final inner = keccak256(Uint8List.fromList([
        ...encodeValue('uint256', 1, {}),
      ]));
      final expected = keccak256(Uint8List.fromList([...inner]));
      expect(encodeValue('uint256[][]', [[1]], {}), expected);
    });

    test('was D3b: an unknown type THROWS instead of signing zeros', () {
      // Signing a message we do not understand is the worst failure here.
      // Refusing is safer and clearer than a rejected signature.
      expect(
        () => encodeValue('SomeTypeNobodyDeclared', 'anything', {}),
        throwsFormatException,
      );
    });

    test('a struct field given a non-object is refused', () {
      final types = {
        'Person': [
          {'name': 'name', 'type': 'string'}
        ],
      };
      expect(() => encodeValue('Person', 'not an object', types), throwsFormatException);
    });
  });

  // The canonical example from the EIP-712 spec itself, which is the only
  // vector here not derived from our own code.
  group('EIP-712 spec example', () {
    final specTypes = {
      'EIP712Domain': [
        {'name': 'name', 'type': 'string'},
        {'name': 'version', 'type': 'string'},
        {'name': 'chainId', 'type': 'uint256'},
        {'name': 'verifyingContract', 'type': 'address'},
      ],
      'Person': [
        {'name': 'name', 'type': 'string'},
        {'name': 'wallet', 'type': 'address'},
      ],
      'Mail': [
        {'name': 'from', 'type': 'Person'},
        {'name': 'to', 'type': 'Person'},
        {'name': 'contents', 'type': 'string'},
      ],
    };

    test('encodeType(Mail) matches the spec string exactly', () {
      expect(
        encodeType('Mail', specTypes),
        'Mail(Person from,Person to,string contents)'
        'Person(string name,address wallet)',
      );
    });

    test('dependencies are sorted by name, not by declaration order', () {
      final t = {
        'Zebra': [
          {'name': 'a', 'type': 'Apple'},
          {'name': 'b', 'type': 'Mango'},
        ],
        'Mango': [{'name': 'x', 'type': 'string'}],
        'Apple': [{'name': 'y', 'type': 'string'}],
      };
      expect(
        encodeType('Zebra', t),
        'Zebra(Apple a,Mango b)Apple(string y)Mango(string x)',
      );
    });

    test('transitive dependencies are collected', () {
      final t = {
        'A': [{'name': 'b', 'type': 'B'}],
        'B': [{'name': 'c', 'type': 'C'}],
        'C': [{'name': 'v', 'type': 'string'}],
      };
      expect(encodeType('A', t), 'A(B b)B(C c)C(string v)');
    });

    test('an array field still pulls its struct into the type string', () {
      // Array VALUE encoding is tested above; the type string must be right
      // on its own -- they are separate concerns.
      final t = {
        'Order': [{'name': 'items', 'type': 'Item[]'}],
        'Item': [{'name': 'sku', 'type': 'string'}],
      };
      expect(encodeType('Order', t), 'Order(Item[] items)Item(string sku)');
    });

    test('a self-referencing type does not loop forever', () {
      final t = {
        'Node': [
          {'name': 'value', 'type': 'string'},
          {'name': 'next', 'type': 'Node'},
        ],
      };
      expect(encodeType('Node', t), 'Node(string value,Node next)');
    });

    test('a flat struct is unchanged by the fix', () {
      // The shapes our own surfaces sign must produce byte-identical output.
      expect(
        encodeType('EIP712Domain', specTypes),
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)',
      );
    });
  });
}
