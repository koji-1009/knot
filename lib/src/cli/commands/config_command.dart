import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:path/path.dart' as p;

/// `knot config get|set|list|delete` — manipulate .npmrc entries.
class ConfigCommand extends Command<int> {
  ConfigCommand() {
    addSubcommand(_ConfigGet());
    addSubcommand(_ConfigSet());
    addSubcommand(_ConfigList());
    addSubcommand(_ConfigDelete());
  }

  @override
  String get name => 'config';

  @override
  String get description => 'Read or write .npmrc entries.';
}

class _ConfigGet extends Command<int> {
  @override
  String get name => 'get';

  @override
  String get description => 'Print a single .npmrc entry.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('a key is required');
    final config = await NpmrcLoader(projectDir: Directory.current.path).load();
    stdout.writeln(config[rest.first] ?? 'undefined');
    return 0;
  }
}

class _ConfigSet extends Command<int> {
  @override
  String get name => 'set';

  @override
  String get description =>
      'Set a key in the project-local .npmrc (creates the file if missing).';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length < 2) usageException('expected `config set <key> <value>`');
    final key = rest[0];
    final value = rest.sublist(1).join(' ');
    final path = p.join(Directory.current.path, '.npmrc');
    final file = File(path);
    final body = await file.exists() ? await file.readAsString() : '';
    final lines = body.split('\n');
    var replaced = false;
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('$key=')) {
        out.add('$key=$value');
        replaced = true;
      } else {
        out.add(line);
      }
    }
    if (!replaced) out.add('$key=$value');
    await file.writeAsString(out.join('\n'));
    return 0;
  }
}

class _ConfigList extends Command<int> {
  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'Print all resolved .npmrc entries.';

  @override
  Future<int> run() async {
    final config = await NpmrcLoader(projectDir: Directory.current.path).load();
    final entries = config.raw.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final e in entries) {
      stdout.writeln('${e.key}=${e.value}');
    }
    return 0;
  }
}

class _ConfigDelete extends Command<int> {
  @override
  String get name => 'delete';

  @override
  List<String> get aliases => const ['rm', 'unset'];

  @override
  String get description => 'Remove a key from the project-local .npmrc.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) usageException('a key is required');
    final key = rest.first;
    final path = p.join(Directory.current.path, '.npmrc');
    final file = File(path);
    if (!await file.exists()) return 0;
    final body = await file.readAsString();
    final out = body
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('$key='))
        .join('\n');
    await file.writeAsString(out);
    return 0;
  }
}
