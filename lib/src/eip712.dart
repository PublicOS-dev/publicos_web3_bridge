import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/keccak.dart';
import 'package:web3dart/web3dart.dart';

/// keccak256, taken from the same place web3dart takes it, so this package can
/// stay free of `publicos_core` (which is where the client reaches for it).
Uint8List keccak256(Uint8List input) => KeccakDigest(256).process(input);

/// EIP-712 typed-data signing.
///
/// Three places where an EIP-712 encoder can silently depart from the spec,
/// each handled per spec here (changing what a signature COVERS is a
/// standards question, not a refactor):
///
/// * **D1** `encodeType` must append every referenced struct type, or nested
///   structs hash wrong. See [encodeType].
/// * **D2** negative ints must be two's complement; a naive encoding leaves an
///   out-of-range -1 in the byte list that wraps to `0xff`, so `int256(-1)`
///   and `uint256(255)` sign identically. See [encodeValue].
/// * **D3** arrays must hash their items; a 32-zero-byte default makes two
///   different arrays sign identically, and an unrecognised type the same.
///
/// The flat-struct path (`string` / `address` / `uint*` / `bool` / `bytesN`)
/// is unaffected by all three, and a test asserts its exact output. Each wrong
/// behaviour is pinned by a test in `test/eip712_test.dart` that asserts the
/// correct result, so it cannot quietly appear.
///
/// The one judgement call beyond the spec: an **unsupported type throws**
/// rather than encoding zeros. Signing a message we cannot encode is the worst
/// available outcome -- it produces a signature nobody can verify and tells
/// the user nothing.
String signTypedData(dynamic typedData, EthPrivateKey privateKey) {
  final map = parseTypedData(typedData);

  final domain = map['domain'] as Map<String, dynamic>?;
  final types = map['types'] as Map<String, dynamic>?;
  final primaryType = map['primaryType'] as String?;
  final message = map['message'] as Map<String, dynamic>?;

  if (domain == null || types == null || primaryType == null || message == null) {
    throw const FormatException('Invalid EIP-712 typed data structure');
  }

  final digest = typedDataDigest(
    domain: domain,
    types: types,
    primaryType: primaryType,
    message: message,
  );

  // signToUint8List signs the payload's keccak, so hand it the 32-byte digest
  // WITHOUT the personal-message prefix -- an EIP-712 signature must not carry
  // it, or the whole point of the 0x19 0x01 envelope is lost.
  final sig = privateKey.signToUint8List(digest);
  return '0x${sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// A dApp may hand typed data over as a JSON string or as an object.
Map<String, dynamic> parseTypedData(dynamic typedData) {
  if (typedData is String) {
    return jsonDecode(typedData) as Map<String, dynamic>;
  }
  if (typedData is Map) return Map<String, dynamic>.from(typedData);
  throw const FormatException('Invalid typed data format');
}

/// The 32 bytes an EIP-712 signature actually covers:
/// `keccak256(0x19 ++ 0x01 ++ domainSeparator ++ hashStruct(message))`.
Uint8List typedDataDigest({
  required Map<String, dynamic> domain,
  required Map<String, dynamic> types,
  required String primaryType,
  required Map<String, dynamic> message,
}) {
  final domainSeparator = hashStruct('EIP712Domain', domain, types);
  final messageHash = hashStruct(primaryType, message, types);
  return keccak256(Uint8List.fromList([
    0x19,
    0x01,
    ...domainSeparator,
    ...messageHash,
  ]));
}

Uint8List hashStruct(
  String typeName,
  Map<String, dynamic> data,
  Map<String, dynamic> types,
) {
  final typeHash = hashType(typeName, types);
  final encoded = encodeData(typeName, data, types);
  return keccak256(Uint8List.fromList([...typeHash, ...encoded]));
}

Uint8List hashType(String typeName, Map<String, dynamic> types) =>
    keccak256(Uint8List.fromList(utf8.encode(encodeType(typeName, types))));

/// The EIP-712 type string: the primary type, then every struct type it
/// references, sorted by name and concatenated.
///
///     Mail(Person from,Person to,string contents)Person(string name,address wallet)
///
/// Both sides build this string independently and hash it, so a single
/// character of difference produces a completely different signature.
///
/// **D1.** Emitting only the primary type makes any typed data containing a
/// nested struct hash to the wrong value, so the dApp's `ecrecover` returns a
/// different address -- the signature is rejected and the interaction simply
/// fails. That hits the nested-struct dApps (Seaport listings, Permit2, 0x
/// orders, Safe transactions); flat structs -- sign-ins, ERC-2612 permits --
/// are unaffected, which is why the bug hides on simple surfaces.
String encodeType(String typeName, Map<String, dynamic> types) {
  final deps = _dependencies(typeName, types)..remove(typeName);
  final ordered = [typeName, ...deps.toList()..sort()];
  return ordered.map((t) => _typeString(t, types)).join();
}

/// One `Name(type field,type field)` fragment, with no dependencies attached.
String _typeString(String typeName, Map<String, dynamic> types) {
  final fields = types[typeName] as List<dynamic>?;
  if (fields == null) return '$typeName()';
  return '$typeName(${fields.map((f) => '${f['type']} ${f['name']}').join(',')})';
}

/// Every struct type reachable from [typeName], including itself.
///
/// A field's type is a dependency when -- after stripping any array suffix --
/// it names a struct declared in [types], so `Person[]` pulls in `Person`.
/// Type collection and value encoding are separate concerns: this decides what
/// the type STRING says, [encodeValue] decides what the bytes are.
Set<String> _dependencies(
  String typeName,
  Map<String, dynamic> types, [
  Set<String>? found,
]) {
  final result = found ?? <String>{};
  if (result.contains(typeName)) return result;
  final fields = types[typeName] as List<dynamic>?;
  if (fields == null) return result;

  result.add(typeName);
  for (final field in fields) {
    final bare = _stripArraySuffix(field['type'] as String);
    if (types.containsKey(bare)) _dependencies(bare, types, result);
  }
  return result;
}

/// `Person[]` -> `Person`, `uint256[3]` -> `uint256`, `string` -> `string`.
String _stripArraySuffix(String type) {
  final i = type.indexOf('[');
  return i == -1 ? type : type.substring(0, i);
}

Uint8List encodeData(
  String typeName,
  Map<String, dynamic> data,
  Map<String, dynamic> types,
) {
  final fields = types[typeName] as List<dynamic>?;
  if (fields == null) return Uint8List(0);

  final out = <int>[];
  for (final field in fields) {
    out.addAll(
      encodeValue(field['type'] as String, data[field['name'] as String], types),
    );
  }
  return Uint8List.fromList(out);
}

/// Encode one field to its 32-byte EIP-712 representation.
List<int> encodeValue(String type, dynamic value, Map<String, dynamic> types) {
  // Arrays first: `bytes32[]` ends in `]` and must not fall into the bytesN
  // branch. An array encodes as the keccak of its items' encodings
  // concatenated -- so it is the item TYPE that decides each element's shape,
  // which is why this recurses rather than special-casing.
  //
  // D3: an array that fell through to the default branch would contribute 32
  // zero bytes, so two different arrays would sign identically.
  if (type.endsWith(']')) {
    final open = type.lastIndexOf('[');
    final itemType = type.substring(0, open);
    final between = type.substring(open + 1, type.length - 1);

    if (value is! List) {
      throw FormatException('EIP-712: $type expects a list, got ${value.runtimeType}');
    }
    if (between.isNotEmpty) {
      final fixed = int.tryParse(between);
      if (fixed == null) {
        throw FormatException('EIP-712: unparseable array length in $type');
      }
      if (value.length != fixed) {
        throw FormatException(
          'EIP-712: $type expects exactly $fixed items, got ${value.length}',
        );
      }
    }

    final out = <int>[];
    for (final item in value) {
      out.addAll(encodeValue(itemType, item, types));
    }
    return keccak256(Uint8List.fromList(out));
  }

  if (type == 'string') {
    return keccak256(Uint8List.fromList(utf8.encode(value?.toString() ?? '')));
  }

  if (type == 'bytes') {
    final bytes = value is String ? hexToBytes(value) : (value as List<int>?) ?? [];
    return keccak256(Uint8List.fromList(bytes));
  }

  if (type == 'address') {
    final addr = (value?.toString() ?? '').replaceFirst('0x', '');
    return hexToBytes(addr.padLeft(64, '0'));
  }

  if (type.startsWith('uint') || type.startsWith('int')) {
    // D2: a negative BigInt's `toRadixString(16)` keeps its '-', padLeft
    // would embed it in the hex, and `int.parse('-1', radix: 16)` produces the
    // value -1 -- not a byte. It wraps to 0xff at the first Uint8List.fromList,
    // so int256(-1) and uint256(255) would sign identically. Hence proper
    // 256-bit two's complement.
    final intValue = _toBigInt(value);

    if (type.startsWith('uint') && intValue.isNegative) {
      throw FormatException('EIP-712: $type cannot hold a negative value');
    }

    final encoded = intValue.isNegative
        ? (BigInt.one << 256) + intValue // two's complement
        : intValue;

    if (encoded.isNegative || encoded.bitLength > 256) {
      throw FormatException('EIP-712: value out of range for $type');
    }

    return hexToBytes(encoded.toRadixString(16).padLeft(64, '0'));
  }

  if (type == 'bool') {
    return hexToBytes((value == true ? '1' : '0').padLeft(64, '0'));
  }

  if (type.startsWith('bytes')) {
    // bytesN is LEFT-aligned (right-padded with zeros), unlike the numeric
    // types. This is correct per spec.
    final bytes =
        value is String ? hexToBytes(value.replaceFirst('0x', '')) : (value as List<int>?) ?? [];
    final padded = List<int>.filled(32, 0);
    for (var i = 0; i < bytes.length && i < 32; i++) {
      padded[i] = bytes[i];
    }
    return padded;
  }

  if (types.containsKey(type)) {
    if (value is! Map) {
      throw FormatException('EIP-712: struct $type expects an object');
    }
    return hashStruct(type, Map<String, dynamic>.from(value), types);
  }

  // An unrecognised type must never become 32 zero bytes. That is the worst
  // possible failure here -- it means we do not understand the message we are
  // about to make the user sign, and we sign it anyway. The verifier then
  // rejects the signature, so the user gets "something went wrong" from the
  // dApp instead of "PublicOS cannot read this request". Refusing is both
  // safer and clearer.
  throw FormatException('EIP-712: unsupported type "$type"');
}

/// Accepts the shapes a dApp actually sends a number as: a JSON int, a decimal
/// string, a `0x` hex string, or an already-parsed BigInt.
BigInt _toBigInt(dynamic value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is String) {
    final s = value.trim();
    if (s.isEmpty) return BigInt.zero;
    if (s.startsWith('-0x')) return -BigInt.parse(s.substring(3), radix: 16);
    if (s.startsWith('0x')) return BigInt.parse(s.substring(2), radix: 16);
    return BigInt.parse(s);
  }
  if (value == null) return BigInt.zero;
  throw FormatException('EIP-712: cannot read ${value.runtimeType} as a number');
}

List<int> hexToBytes(String hex) {
  var h = hex.replaceFirst('0x', '');
  if (h.length % 2 != 0) h = '0$h';
  return List.generate(
    h.length ~/ 2,
    (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

/// `eth_signTypedData*` params: `[address, typedData]`.
///
/// Note the order is address-first, matching `eth_sign` rather than
/// `personal_sign`.
({dynamic typedData, String address}) signTypedDataParams(List<dynamic>? params) {
  if (params == null || params.length < 2) {
    throw const FormatException('Invalid signTypedData parameters');
  }
  return (typedData: params[1], address: params[0] as String);
}
