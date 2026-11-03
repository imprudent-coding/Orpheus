import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';
import 'package:mtls_proxy/src/access_token.dart' show AccessGuard;

void main() {
  group('AccessToken', () {
    test('- is 32 random bytes, URL-safe, without padding', () {
      final token = AccessToken.generate();

      expect(token.value, hasLength(43));
      expect(token.value, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(base64Url.decode('${token.value}='), hasLength(32));
    });

    test('- differs at every launch', () {
      final tokens = {
        for (var i = 0; i < 50; i++) AccessToken.generate().value,
      };

      expect(tokens, hasLength(50));
    });

    test('- refuses fewer than 32 bytes', () {
      expect(() => AccessToken.generate(byteLength: 16), throwsArgumentError);
    });

    test('- accepts only the exact token', () {
      final token = AccessToken.generate();

      expect(token.accepts(token.value), isTrue);
      expect(token.accepts(''), isFalse);
      expect(token.accepts(token.value.substring(1)), isFalse);
      expect(token.accepts('${token.value}x'), isFalse);
      expect(token.accepts(token.value.toUpperCase()), isFalse);
    });

    test('- never prints the secret', () {
      final token = AccessToken.generate();

      expect(token.toString(), isNot(contains(token.value)));
    });
  });

  group('constantTimeEquals', () {
    test('- compares content and length', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [9, 2, 3]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3, 0]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 0]), isFalse);
      expect(constantTimeEquals([], []), isTrue);
      expect(constantTimeEquals([0], []), isFalse);
    });

    test('- walks the whole secret even when the first byte differs', () {
      // The comparison has no early exit: every byte of the secret is read,
      // whatever the candidate looks like.
      final reads = <int>[];
      final secret = _RecordingList([5, 6, 7, 8], reads);

      constantTimeEquals(secret, [0]);
      expect(reads, [0, 1, 2, 3]);

      reads.clear();
      constantTimeEquals(secret, [5, 6, 7, 8, 9, 10]);
      expect(reads, [0, 1, 2, 3]);
    });
  });

  group('AccessGuard', () {
    test('- blocks after too many failures within the window', () {
      var now = DateTime(2026);
      final guard =
          AccessGuard(
              maxFailures: 3,
              cooldown: const Duration(seconds: 30),
              clock: () => now,
            )
            ..recordFailure()
            ..recordFailure();
      expect(guard.isBlocked, isFalse);
      guard.recordFailure();
      expect(guard.isBlocked, isTrue);

      now = now.add(const Duration(seconds: 29));
      expect(guard.isBlocked, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(guard.isBlocked, isFalse);
    });

    test('- forgets failures older than the window', () {
      var now = DateTime(2026);
      final guard = AccessGuard(maxFailures: 3, clock: () => now)
        ..recordFailure();
      now = now.add(const Duration(seconds: 11));
      guard
        ..recordFailure()
        ..recordFailure();

      expect(guard.isBlocked, isFalse);
    });
  });
}

class _RecordingList extends ListBase<int> {
  _RecordingList(this._values, this._reads);

  final List<int> _values;
  final List<int> _reads;

  @override
  int operator [](int index) {
    _reads.add(index);
    return _values[index];
  }

  @override
  void operator []=(int index, int value) => _values[index] = value;

  @override
  int get length => _values.length;

  @override
  set length(int value) => _values.length = value;
}
