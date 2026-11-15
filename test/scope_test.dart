// Scope matching is the safeguard's load-bearing predicate: it decides whether
// a page keeps the wallet bridge. The segment-boundary case is the one a naive
// `startsWith` gets wrong, so it is pinned here.
//
// Imports the source file directly rather than the barrel: the barrel pulls in
// publicos_core, whose FFI-heavy transitive deps are irrelevant to this logic.
import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/web_view_host.dart';

void main() {
  group('WebScope path-locked', () {
    final s = WebScope.of(Uri.parse('https://a.com/page'), lockToPath: true);
    final cases = <String, bool>{
      'https://a.com/page': true,
      'https://a.com/page/sub': true,
      'https://a.com/page/sub/deeper': true,
      'https://a.com/pagefoo': false, // segment boundary, NOT string prefix
      'https://a.com/other': false,
      'https://a.com/': false,
      'https://evil.com/page': false,
      'http://a.com/page': false, // scheme change is an origin change
      'https://sub.a.com/page': false, // subdomain is a different origin
    };
    cases.forEach((url, want) {
      test('$url -> $want', () => expect(s.allows(Uri.parse(url)), want));
    });
  });

  test('origin-only scope admits any path on the same origin', () {
    final s = WebScope.of(Uri.parse('https://a.com/page'));
    expect(s.allows(Uri.parse('https://a.com/anything')), isTrue);
    expect(s.allows(Uri.parse('https://a.com/')), isTrue);
    expect(s.allows(Uri.parse('https://b.com/page')), isFalse);
  });

  test('unrestricted admits everything', () {
    expect(WebScope.unrestricted.allows(Uri.parse('https://whatever.io/x')), isTrue);
    expect(WebScope.unrestricted.isUnrestricted, isTrue);
  });

  test('explicit port mismatch is out of scope', () {
    final s = WebScope(origin: Uri.parse('https://a.com:8443'));
    expect(s.allows(Uri.parse('https://a.com:8443/x')), isTrue);
    expect(s.allows(Uri.parse('https://a.com/x')), isFalse);
  });
}
