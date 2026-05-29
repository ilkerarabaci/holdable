import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography from the Prism Studio system (docs/design-handoff.md §Typography).
///
/// Display & UI = Manrope. Technical / specs / metadata = JetBrains Mono.
/// No serif anywhere. Letter-spacing in the handoff is expressed in `em`;
/// Flutter uses logical pixels, so each value is `fontSize * em`.
class PrismText {
  PrismText._();

  /// Mono style for metadata/specs (vertex/face counts, file sizes).
  /// Not part of the standard [TextTheme] slots, so exposed directly.
  static TextStyle monoBody(Color color) => GoogleFonts.jetBrainsMono(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: color,
      );

  static TextTheme themeFor(Color primary) {
    final manrope = GoogleFonts.manropeTextTheme();

    TextStyle manropeStyle({
      required double size,
      required FontWeight weight,
      double letterSpacing = 0,
    }) =>
        GoogleFonts.manrope(
          fontSize: size,
          fontWeight: weight,
          letterSpacing: letterSpacing,
          color: primary,
        );

    return manrope.copyWith(
      // displayLarge: 28 / Manrope 700 / -0.02em
      displayLarge: manropeStyle(size: 28, weight: FontWeight.w700, letterSpacing: -0.56),
      // displayMedium: 22 / Manrope 700 / -0.02em
      displayMedium: manropeStyle(size: 22, weight: FontWeight.w700, letterSpacing: -0.44),
      // titleLarge: 18 / Manrope 600 / -0.01em
      titleLarge: manropeStyle(size: 18, weight: FontWeight.w600, letterSpacing: -0.18),
      // bodyLarge: 15 / Manrope 500
      bodyLarge: manropeStyle(size: 15, weight: FontWeight.w500),
      // bodyMedium: 13 / Manrope 500
      bodyMedium: manropeStyle(size: 13, weight: FontWeight.w500),
      // labelSmall: 11 / JetBrains Mono 500 / +0.04em / uppercase
      labelSmall: GoogleFonts.jetBrainsMono(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.44,
        color: primary,
      ),
    );
  }
}
