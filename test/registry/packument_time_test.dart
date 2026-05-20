import 'dart:convert';

import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

void main() {
  group('Packument time', () {
    test('parses per-version publish times, skips metadata keys', () {
      final pack = Packument.fromJson({
        'name': 'react',
        'dist-tags': {'latest': '18.2.0'},
        'versions': {
          '17.0.2': {'name': 'react', 'version': '17.0.2'},
          '18.2.0': {'name': 'react', 'version': '18.2.0'},
        },
        'time': {
          'created': '2011-10-26T17:46:21.942Z',
          'modified': '2023-06-15T12:00:00.000Z',
          '17.0.2': '2021-03-22T22:46:21.000Z',
          '18.2.0': '2022-06-14T19:00:00.000Z',
        },
      });
      expect(pack.publishTimes.keys, ['17.0.2', '18.2.0']);
      expect(
        pack.publishTimes['18.2.0'],
        DateTime.parse('2022-06-14T19:00:00.000Z'),
      );
    });

    test('round-trips through toJson/fromJson', () {
      final original = Packument.fromJson({
        'name': 'x',
        'dist-tags': {'latest': '1.0.0'},
        'versions': {
          '1.0.0': {'name': 'x', 'version': '1.0.0'},
        },
        'time': {'1.0.0': '2024-01-15T10:00:00.000Z'},
      });
      final round = Packument.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(original.toJson())) as Map,
        ),
      );
      expect(round.publishTimes['1.0.0'], original.publishTimes['1.0.0']);
    });

    test('empty publishTimes is omitted from slim JSON', () {
      final pack = Packument.fromJson(<String, dynamic>{
        'name': 'x',
        'dist-tags': const <String, dynamic>{},
        'versions': const <String, dynamic>{},
      });
      expect(pack.toJson().containsKey('time'), isFalse);
    });

    test('ignores malformed time entries silently', () {
      final pack = Packument.fromJson({
        'name': 'x',
        'versions': {
          '1.0.0': {'name': 'x', 'version': '1.0.0'},
        },
        'time': {'1.0.0': 'not-a-date'},
      });
      expect(pack.publishTimes, isEmpty);
    });
  });
}
