import 'package:knot/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  test('KnotError subclasses carry message and cause', () {
    const e = NetworkError('timeout', statusCode: 504);
    expect(e.message, 'timeout');
    expect(e.statusCode, 504);
    expect(e.toString(), contains('NetworkError'));
    expect(e.toString(), contains('timeout'));
  });

  test('IntegrityError captures expected vs actual', () {
    const e = IntegrityError('mismatch', expected: 'abc', actual: 'def');
    expect(e.expected, 'abc');
    expect(e.actual, 'def');
  });

  test('CancelledError has default message', () {
    const e = CancelledError();
    expect(e.message, isNotEmpty);
  });
}
