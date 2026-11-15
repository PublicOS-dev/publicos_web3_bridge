import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/web_storage_profile.dart';

void main() {
  const session = '0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B';

  group('WebStorageProfileId', () {
    test('account id is the lowercased session address', () {
      expect(WebStorageProfileId.account(session), session.toLowerCase());
    });

    test('two spellings of one key are one id', () {
      expect(
        WebStorageProfileId.account(session),
        WebStorageProfileId.account(session.toLowerCase()),
      );
      expect(
        WebStorageProfileId.account('  $session '),
        WebStorageProfileId.account(session),
      );
    });

    test('wallet id is prefixed and never equals the account id', () {
      final w = WebStorageProfileId.wallet(session);
      expect(w, 'wallet-${session.toLowerCase()}');
      expect(w, isNot(WebStorageProfileId.account(session)));
    });

    test('ids are filesystem-safe', () {
      for (final id in [
        WebStorageProfileId.account(session),
        WebStorageProfileId.wallet(session),
      ]) {
        expect(
          id,
          matches(RegExp(r'^[a-z0-9-]+$')),
          reason: r'a Windows folder name may not contain : / \ or case',
        );
      }
    });

    test('rejects anything that is not a session address', () {
      expect(() => WebStorageProfileId.account('citizen'), throwsArgumentError);
      expect(() => WebStorageProfileId.account('0x1234'), throwsArgumentError);
      expect(() => WebStorageProfileId.wallet(''), throwsArgumentError);
    });

    test('uuidFor is deterministic and distinct per profile', () {
      final a1 =
          WebStorageProfileId.uuidFor(WebStorageProfileId.account(session));
      final a2 =
          WebStorageProfileId.uuidFor(WebStorageProfileId.account(session));
      final w = WebStorageProfileId.uuidFor(WebStorageProfileId.wallet(session));
      expect(a1, a2);
      expect(a1, isNot(w));
      expect(
        a1,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )),
      );
    });
  });

  group('uuidV5', () {
    test('matches the RFC 4122 reference vector', () {
      // Python: uuid.uuid5(uuid.NAMESPACE_DNS, 'python.org')
      expect(
        uuidV5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'python.org'),
        '886313e1-3b8a-5372-9b90-0c9aee199e5d',
      );
    });

    test('rejects a malformed namespace', () {
      expect(() => uuidV5('nope', 'x'), throwsArgumentError);
    });
  });

  group('WebStorageProfile<C>', () {
    test('is implementable with any controller type', () async {
      final p = _Fake();
      final id = '0x${'a' * 40}';
      expect(await p.isolates, isTrue);
      expect(await p.createController(id), 'ctl:$id');
    });
  });
}

class _Fake implements WebStorageProfile<String> {
  @override
  Future<bool> get isolates async => true;

  @override
  Future<String> createController(String profileId) async => 'ctl:$profileId';

  @override
  Future<void> wipeAll() async {}
}
