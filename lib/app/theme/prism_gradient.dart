import 'package:flutter/widgets.dart';

/// The single Holdable brand accent. Identical in dark and light themes.
///
/// Iridescent gradient `#FF5CB4 → #8B6CFF → #4FE0E5` (0% / 50% / 100%).
/// This is the ONLY brand accent in the app — do not substitute or add
/// secondary accent colors. Centralized here so the rule is enforced by
/// having a single source of truth.
class PrismGradient {
  PrismGradient._();

  static const Color pink = Color(0xFFFF5CB4);
  static const Color violet = Color(0xFF8B6CFF);
  static const Color cyan = Color(0xFF4FE0E5);

  static const List<Color> colors = [pink, violet, cyan];
  static const List<double> stops = [0.0, 0.5, 1.0];

  /// Default left→right iridescent sweep.
  static const LinearGradient linear = LinearGradient(
    colors: colors,
    stops: stops,
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// Diagonal variant for larger fills (hero marks, edges).
  static const LinearGradient diagonal = LinearGradient(
    colors: colors,
    stops: stops,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
