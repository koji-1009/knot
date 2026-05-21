import 'package:knot/src/policy/build_script_gate.dart';
import 'package:test/test.dart';

void main() {
  group('matchesAllowPattern', () {
    test('exact name match', () {
      expect(matchesAllowPattern('react', ['react']), isTrue);
      expect(matchesAllowPattern('react', ['react-dom']), isFalse);
    });

    test('trailing * glob', () {
      expect(matchesAllowPattern('react-dom', ['react*']), isTrue);
      expect(matchesAllowPattern('preact', ['react*']), isFalse);
    });

    test('@scope/* matches every package in scope', () {
      expect(matchesAllowPattern('@types/node', ['@types/*']), isTrue);
      expect(matchesAllowPattern('@types/react', ['@types/*']), isTrue);
      expect(matchesAllowPattern('@radix/ui', ['@types/*']), isFalse);
    });

    test('empty pattern list never matches', () {
      expect(matchesAllowPattern('react', const []), isFalse);
    });
  });

  group('BuildScriptTriggers', () {
    test('fromScripts picks up preinstall/install/postinstall', () {
      final t = BuildScriptTriggers.fromScripts(const {
        'preinstall': 'do',
        'postinstall': 'cleanup',
      });
      expect(t.hasPreinstall, isTrue);
      expect(t.hasInstall, isFalse);
      expect(t.hasPostinstall, isTrue);
      expect(t.any, isTrue);
    });

    test('prepare alone is NOT a trigger', () {
      final t = BuildScriptTriggers.fromScripts(const {'prepare': 'do'});
      expect(t.any, isFalse);
    });

    test('binding.gyp / .hooks counted as triggers', () {
      const t = BuildScriptTriggers(hasBindingGyp: true);
      expect(t.any, isTrue);
      const t2 = BuildScriptTriggers(hasHooksDir: true);
      expect(t2.any, isTrue);
    });
  });

  group('BuildScriptPolicy.evaluate', () {
    const trigger = BuildScriptTriggers(hasPostinstall: true);
    const noTrigger = BuildScriptTriggers();

    test('no trigger → noTrigger', () {
      const policy = BuildScriptPolicy();
      expect(
        policy.evaluate('react', noTrigger),
        BuildScriptDecision.noTrigger,
      );
    });

    test('trigger + allowBuilds match → allow', () {
      const policy = BuildScriptPolicy(allowBuilds: ['esbuild']);
      expect(
        policy.evaluate('esbuild', trigger),
        BuildScriptDecision.allow,
      );
    });

    test('trigger + no match + non-strict → skip', () {
      const policy = BuildScriptPolicy();
      expect(
        policy.evaluate('something', trigger),
        BuildScriptDecision.skip,
      );
    });

    test('trigger + no match + strict → fail', () {
      const policy = BuildScriptPolicy(strictDepBuilds: true);
      expect(
        policy.evaluate('something', trigger),
        BuildScriptDecision.fail,
      );
    });

    test('dangerouslyAllowAllBuilds bypasses every check', () {
      const policy = BuildScriptPolicy(
        strictDepBuilds: true,
        dangerouslyAllowAllBuilds: true,
      );
      expect(
        policy.evaluate('anything', trigger),
        BuildScriptDecision.allow,
      );
    });

    test('@scope/* pattern allows whole scope', () {
      const policy = BuildScriptPolicy(allowBuilds: ['@types/*']);
      expect(
        policy.evaluate('@types/node', trigger),
        BuildScriptDecision.allow,
      );
    });

    test('v11Default has strictDepBuilds=true', () {
      expect(BuildScriptPolicy.v11Default.strictDepBuilds, isTrue);
    });
  });
}
