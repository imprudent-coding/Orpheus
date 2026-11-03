import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// The secret path prefix that authorizes a request to the loopback proxy.
///
/// Native players cannot always send custom headers, so the token travels as
/// the first path segment: `http://127.0.0.1:<port>/<token>/...`.
@immutable
class AccessToken {
  AccessToken._(this.value) : _bytes = utf8.encode(value);

  /// [byteLength] random bytes from [Random.secure], base64url encoded without
  /// padding (43 characters for the default 32 bytes).
  factory AccessToken.generate({int byteLength = 32}) {
    if (byteLength < 32) {
      throw ArgumentError.value(byteLength, 'byteLength', 'must be >= 32');
    }
    final random = Random.secure();
    final bytes = [for (var i = 0; i < byteLength; i++) random.nextInt(256)];
    return AccessToken._(base64Url.encode(bytes).replaceAll('=', ''));
  }

  final String value;
  final List<int> _bytes;

  /// Compares [presented] with this token in constant time.
  bool accepts(String presented) =>
      constantTimeEquals(_bytes, utf8.encode(presented));

  /// Never prints the secret.
  @override
  String toString() => 'AccessToken(<redacted>)';
}

/// Compares [secret] with [candidate] in time that depends only on the length
/// of [secret], never on where the first difference is or on the length of
/// [candidate].
///
/// The loop always walks every byte of [secret] and folds every difference,
/// including a length mismatch, into one accumulator that is checked once at
/// the end.
bool constantTimeEquals(List<int> secret, List<int> candidate) {
  var difference = secret.length ^ candidate.length;
  for (var i = 0; i < secret.length; i++) {
    final other = i < candidate.length ? candidate[i] : 0;
    difference |= secret[i] ^ other;
  }
  return difference == 0;
}

/// Closes the proxy to new connections for a while after repeated requests
/// with an invalid token, so another app on the device cannot keep guessing.
class AccessGuard {
  AccessGuard({
    this.maxFailures = 30,
    this.window = const Duration(seconds: 10),
    this.cooldown = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Invalid requests tolerated within [window] before the cooldown starts.
  final int maxFailures;
  final Duration window;
  final Duration cooldown;
  final DateTime Function() _clock;

  final _failures = <DateTime>[];
  DateTime? _blockedUntil;

  bool get isBlocked {
    final until = _blockedUntil;
    if (until == null) return false;
    if (_clock().isBefore(until)) return true;
    _blockedUntil = null;
    _failures.clear();
    return false;
  }

  void recordFailure() {
    final now = _clock();
    _failures
      ..add(now)
      ..removeWhere((at) => now.difference(at) > window);
    if (_failures.length >= maxFailures) {
      _blockedUntil = now.add(cooldown);
      _failures.clear();
    }
  }
}
