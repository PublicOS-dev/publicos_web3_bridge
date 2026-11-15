import 'dart:convert';
import 'dart:typed_data';

import 'package:web3dart/web3dart.dart';

/// EIP-191 `personal_sign`.
///
/// **Deliberate change from the client widget.** The original hand-rolled the
/// whole thing: build the `\x19Ethereum Signed Message:\n<len>` prefix, keccak
/// it, unpack the private key into bytes by hex round-trip, sign, then
/// normalise `v` from 0/1 to 27/28. That worked, but it reached `keccak256`
/// and `sign` **through `publicos_core`**, which this package must not import
/// -- and every line of hand-rolled signing is a line that can be subtly wrong.
///
/// `EthPrivateKey.signPersonalMessageToUint8List` is web3dart's own
/// implementation of exactly that procedure, prefix included. Same output,
/// first-party, no Core.
///
/// Both `personal_sign` and `eth_sign` end up here. They differ only in the
/// ORDER of their params -- an EIP quirk, not a difference in what is signed:
///
/// * `personal_sign` -> `[message, address]`
/// * `eth_sign`      -> `[address, message]`
///
/// Getting that backwards signs the user's own address as though it were a
/// message, which is why [personalSignParams] and [ethSignParams] exist rather
/// than a bare `params[0]` at each call site.
String signPersonalMessage(String message, EthPrivateKey privateKey) {
  final signature =
      privateKey.signPersonalMessageToUint8List(decodeMessage(message));
  return '0x${_hex(signature)}';
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A dApp may send the message as hex or as plain text, and the two are not
/// distinguishable by inspection -- `0xdeadbeef` is valid text. The convention
/// every wallet follows is: a leading `0x` means hex.
Uint8List decodeMessage(String message) {
  if (!message.startsWith('0x')) {
    return Uint8List.fromList(utf8.encode(message));
  }
  final hex = message.substring(2);
  return Uint8List.fromList(
    List.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ),
  );
}

/// `personal_sign` params: `[message, address]`.
({String message, String address}) personalSignParams(List<dynamic>? params) {
  if (params == null || params.length < 2) {
    throw const FormatException('Invalid personal_sign parameters');
  }
  return (message: params[0] as String, address: params[1] as String);
}

/// `eth_sign` params: `[address, message]` -- REVERSED from personal_sign.
({String message, String address}) ethSignParams(List<dynamic>? params) {
  if (params == null || params.length < 2) {
    throw const FormatException('Invalid eth_sign parameters');
  }
  return (message: params[1] as String, address: params[0] as String);
}
