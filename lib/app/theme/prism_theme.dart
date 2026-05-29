import 'package:flutter/material.dart';

import 'prism_colors.dart';
import 'prism_gradient.dart';
import 'prism_text.dart';

/// Assembles [ThemeData] for dark (default) and light from Prism tokens.
class PrismTheme {
  PrismTheme._();

  static ThemeData dark = _build(PrismColors.dark, Brightness.dark);
  static ThemeData light = _build(PrismColors.light, Brightness.light);

  static ThemeData _build(PrismColors c, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: PrismGradient.violet,
      brightness: brightness,
      surface: c.surface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.bg,
      colorScheme: scheme.copyWith(
        primary: PrismGradient.violet,
        surface: c.surface,
        onSurface: c.textPrimary,
      ),
      textTheme: PrismText.themeFor(c.textPrimary),
      extensions: [c],
      splashFactory: InkRipple.splashFactory,
      dividerColor: c.borderHairline,
    );
  }
}
