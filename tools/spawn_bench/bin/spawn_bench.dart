// Microbench for [WorkerPool.spawn]. Reports min / median / max wall
// time over the given number of runs (default 10), disposing the
// pool between runs so each measurement spawns a fresh set of
// isolates.
//
//   dart build cli --target bin/spawn_bench.dart -o /tmp/spawn-bench
//   /tmp/spawn-bench/bundle/bin/spawn_bench [runs]
import 'dart:io';

import 'package:knot/src/store/worker_pool.dart';

Future<void> main(List<String> args) async {
  final runs = args.isNotEmpty ? int.parse(args[0]) : 10;
  final size = Platform.numberOfProcessors;
  final timesUs = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    final pool = await WorkerPool.spawn(size: size);
    sw.stop();
    timesUs.add(sw.elapsedMicroseconds);
    await pool.dispose();
  }
  timesUs.sort();
  String ms(int us) => (us / 1000).toStringAsFixed(1);
  print('size=$size runs=$runs');
  print('min:    ${ms(timesUs.first)} ms');
  print('median: ${ms(timesUs[timesUs.length ~/ 2])} ms');
  print('max:    ${ms(timesUs.last)} ms');
  print('raw_ms: ${[for (final us in timesUs) ms(us)]}');
}
