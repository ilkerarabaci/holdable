import 'package:flutter/material.dart';

/// Themeable color tokens from the Prism Studio design system
/// (see design-source/ and docs/design-handoff.md).
///
/// Exposed as a [ThemeExtension] so both themes carry the same token set
/// and `Theme.of(context).extension<PrismColors>()` resolves the right
/// values. The brand gradient is intentionally NOT here — it lives in
/// [PrismGradient] because it is identical across themes.
@immutable
class PrismColors extends ThemeExtension<PrismColors> {
  const PrismColors({
    required this.bg,
    required this.surface,
    required this.textPrimary,
    required this.textMuted,
    required this.borderHairline,
    required this.glass1,
    required this.glass2,
  });

  final Color bg;
  final Color surface;
  final Color textPrimary;
  final Color textMuted;
  final Color borderHairline;

  /// Liquid-glass card fill gradient endpoints (top → bottom).
  final Color glass1;
  final Color glass2;

  static const dark = PrismColors(
    bg: Color(0xFF0E0E10),
    surface: Color(0xFF1A1A1F),
    textPrimary: Color(0xFFF5F5F7),
    textMuted: Color(0xFF8A8A95),
    borderHairline: Color(0x14FFFFFF), // rgba(255,255,255,0.08)
    glass1: Color(0x0AFFFFFF), // rgba(255,255,255,0.04)
    glass2: Color(0x05FFFFFF), // rgba(255,255,255,0.02)
  );

  static const light = PrismColors(
    bg: Color(0xFFF4F2EE),
    surface: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF1A1A1C),
    textMuted: Color(0xFF5A5A5E),
    borderHairline: Color(0x14000000), // rgba(0,0,0,0.08)
    glass1: Color(0xD9FFFFFF), // rgba(255,255,255,0.85)
    glass2: Color(0x99FFFFFF), // rgba(255,255,255,0.6)
  );

  @override
  PrismColors copyWith({
    Color? bg,
    Color? surface,
    Color? textPrimary,
    Color? textMuted,
    Color? borderHairline,
    Color? glass1,
    Color? glass2,
  }) {
    return PrismColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      borderHairline: borderHairline ?? this.borderHairline,
      glass1: glass1 ?? this.glass1,
      glass2: glass2 ?? this.glass2,
    );
  }

  @override
  PrismColors lerp(ThemeExtension<PrismColors>? other, double t) {
    if (other is! PrismColors) return this;
    return PrismColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      borderHairline: Color.lerp(borderHairline, other.borderHairline, t)!,
      glass1: Color.lerp(glass1, other.glass1, t)!,
      glass2: Color.lerp(glass2, other.glass2, t)!,
    );
  }
}

/// Sugar for `Theme.of(context).extension<PrismColors>()!`.
extension PrismColorsX on BuildContext {
  PrismColors get prism => Theme.of(this).extension<PrismColors>()!;
}
