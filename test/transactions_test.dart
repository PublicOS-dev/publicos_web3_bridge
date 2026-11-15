// Transaction building is pure and therefore fully testable: everything a dApp
// sends arrives as 0x hex strings, and the interesting behaviour is which
// fields are left NULL so the node can fill them.
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/transactions.dart';

void main() {
  group('field decoding', () {
    test('value is hex wei; absent means zero', () {
      expect(buildTransaction({'value': '0x1'}).value!.getInWei, BigInt.one);
      expect(buildTransaction({'value': '0xde0b6b3a7640000'}).value!.getInWei,
          BigInt.parse('1000000000000000000'));
      expect(buildTransaction({}).value!.getInWei, BigInt.zero);
    });

    test('to is optional - a contract deployment has none', () {
      expect(buildTransaction({'to': '0x${'11' * 20}'}).to, isNotNull);
      expect(buildTransaction({}).to, isNull);
      expect(buildTransaction({'to': ''}).to, isNull,
          reason: 'an empty string is not an address');
    });

    test('data: "0x" and "" mean NO calldata, not empty calldata', () {
      // A plain value transfer must not carry a zero-length data field.
      expect(buildTransaction({'data': '0x'}).data, isNull);
      expect(buildTransaction({'data': ''}).data, isNull);
      expect(buildTransaction({}).data, isNull);
      expect(buildTransaction({'data': '0xdeadbeef'}).data, [0xde, 0xad, 0xbe, 0xef]);
    });

    test('gas and nonce accept hex or decimal', () {
      expect(buildTransaction({'gas': '0x5208'}).maxGas, 21000);
      expect(buildTransaction({'nonce': '0x7'}).nonce, 7);
      expect(buildTransaction({'gas': '21000'}).maxGas, 21000);
    });
  });

  group('omitted fields stay null so the node fills them', () {
    // Defaulting these here would silently override a node that knows better.
    test('nonce, gas and price are all null when absent', () {
      final tx = buildTransaction({'to': '0x${'11' * 20}'});
      expect(tx.nonce, isNull);
      expect(tx.maxGas, isNull);
      expect(tx.gasPrice, isNull);
      expect(tx.maxFeePerGas, isNull);
    });
  });

  group('the 1559 / legacy split turns on ONE field', () {
    test('maxFeePerGas present -> 1559, and gasPrice is not set', () {
      final tx = buildTransaction({
        'maxFeePerGas': '0x77359400',
        'maxPriorityFeePerGas': '0x3b9aca00',
      });
      expect(tx.maxFeePerGas!.getInWei, BigInt.from(2000000000));
      expect(tx.maxPriorityFeePerGas!.getInWei, BigInt.from(1000000000));
      expect(tx.gasPrice, isNull);
    });

    test('maxPriorityFeePerGas falls back to maxFeePerGas when absent', () {
      // A dApp sending only a cap means "tip up to the cap".
      final tx = buildTransaction({'maxFeePerGas': '0x77359400'});
      expect(tx.maxPriorityFeePerGas!.getInWei, tx.maxFeePerGas!.getInWei);
    });

    test('maxFeePerGas absent -> legacy, gasPrice honoured', () {
      final tx = buildTransaction({'gasPrice': '0x3b9aca00'});
      expect(tx.gasPrice!.getInWei, BigInt.from(1000000000));
      expect(tx.maxFeePerGas, isNull);
    });

    test('gasPrice is IGNORED when maxFeePerGas is present', () {
      final tx = buildTransaction({
        'maxFeePerGas': '0x77359400',
        'gasPrice': '0x3b9aca00',
      });
      expect(tx.gasPrice, isNull, reason: '1559 wins, the two cannot coexist');
    });
  });

  group('params', () {
    test('takes the first element as the transaction object', () {
      final tx = transactionParams([
        {'to': '0xabc', 'value': '0x1'}
      ]);
      expect(tx['to'], '0xabc');
    });

    test('refuses an empty or non-object payload rather than sending blank', () {
      expect(() => transactionParams(null), throwsFormatException);
      expect(() => transactionParams([]), throwsFormatException);
      expect(() => transactionParams(['not an object']), throwsFormatException);
    });
  });

  group('a realistic dApp payload', () {
    test('an ERC-20 transfer builds correctly end to end', () {
      final tx = buildTransaction({
        'from': '0x${'aa' * 20}',
        'to': '0x${'bb' * 20}',
        'value': '0x0',
        'data': '0xa9059cbb${'00' * 12}${'cc' * 20}${'00' * 31}64',
        'gas': '0xd6d8',
        'maxFeePerGas': '0x77359400',
      });

      expect(tx.to!.with0x.toLowerCase(), '0x${'bb' * 20}');
      expect(tx.value!.getInWei, BigInt.zero, reason: 'a token move sends no ether');
      expect(tx.data!.length, 68, reason: '4-byte selector + 2 words');
      expect(tx.data!.sublist(0, 4), [0xa9, 0x05, 0x9c, 0xbb]);
      expect(tx.maxGas, 55000); // 0xd6d8
      expect(tx.maxFeePerGas, isNotNull);
      expect(tx.nonce, isNull, reason: 'left for the node');
    });
  });
}
