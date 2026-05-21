import 'package:knot/src/policy/peer_dependency_rules.dart';
import 'package:test/test.dart';

void main() {
  group('PeerDependencyRules', () {
    test('none is empty', () {
      const rules = PeerDependencyRules.none;
      expect(rules.allowedVersions, isEmpty);
      expect(rules.ignoreMissing, isEmpty);
      expect(rules.allowAny, isEmpty);
    });

    test('isMissingIgnored honors the list', () {
      const rules = PeerDependencyRules(ignoreMissing: ['react']);
      expect(rules.isMissingIgnored('react'), isTrue);
      expect(rules.isMissingIgnored('react-dom'), isFalse);
    });

    test('isAnyAllowed honors the list', () {
      const rules = PeerDependencyRules(allowAny: ['typescript']);
      expect(rules.isAnyAllowed('typescript'), isTrue);
      expect(rules.isAnyAllowed('eslint'), isFalse);
    });

    test('allowedFor returns the explicit ranges in order', () {
      const rules = PeerDependencyRules(
        allowedVersions: {
          'react': ['^17', '^18'],
        },
      );
      expect(rules.allowedFor('react'), ['^17', '^18']);
      expect(rules.allowedFor('missing'), isEmpty);
    });
  });
}
