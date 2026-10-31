// Reading what the native engine sends. iOS sends every number as a double and Android sends some as
// integers, so numbers are always read as num. Maps arrive as Map<Object?, Object?> at every depth.

Map<String, Object?> asMap(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', _deep(item))) : <String, Object?>{};

Map<String, Object?>? asMapOrNull(Object? value) => value is Map ? asMap(value) : null;

Object? _deep(Object? value) => switch (value) {
      Map() => asMap(value),
      List() => value.map(_deep).toList(),
      _ => value,
    };

double asDouble(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

double? asDoubleOrNull(Object? value) => value is num ? value.toDouble() : null;

int asInt(Object? value, [int fallback = 0]) => value is num ? value.toInt() : fallback;

int? asIntOrNull(Object? value) => value is num ? value.toInt() : null;

bool asBool(Object? value, [bool fallback = false]) => value is bool ? value : fallback;

bool? asBoolOrNull(Object? value) => value is bool ? value : null;

String asString(Object? value, [String fallback = '']) => value is String ? value : fallback;

String? asStringOrNull(Object? value) => value is String ? value : null;

Map<String, String>? asStringMapOrNull(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', '$item')) : null;

/// The enum value whose wire string is [wire], or null for anything else (including values a newer engine adds).
T? enumOrNull<T extends Enum>(Iterable<T> values, Object? wire, Object Function(T value) wireOf) {
  for (final value in values) {
    if (wireOf(value) == wire) return value;
  }
  return null;
}
