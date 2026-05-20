import 'package:knot/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  test('ProgressEvent variants are constructable', () {
    final events = <ProgressEvent>[
      const ResolutionStarted(),
      const ResolutionCompleted(resolved: 10, elapsed: Duration(seconds: 1)),
      const TarballFetchStarted(package: 'react', version: '18.0.0'),
      const TarballFetchProgress(
        package: 'react',
        version: '18.0.0',
        downloaded: 1024,
        total: 4096,
      ),
      const TarballFetched(package: 'react', version: '18.0.0'),
      const TarballExtracted(package: 'react', version: '18.0.0'),
      const PackageLinked(package: 'react', version: '18.0.0'),
      const ScriptStarted(package: 'sharp', event: 'install'),
      const ScriptCompleted(package: 'sharp', event: 'install', exitCode: 0),
      const InstallSummary(
        added: 100,
        removed: 0,
        elapsed: Duration(seconds: 5),
      ),
    ];
    expect(events.length, 10);
  });
}
