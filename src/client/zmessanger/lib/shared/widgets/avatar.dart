import 'package:flutter/material.dart';

/// Colored circle avatar showing the first letter of a name.
///
/// The background color is deterministically derived from the name's
/// hash code so the same contact always gets the same color, providing
/// visual consistency across the app without storing color preferences.
class LetterAvatar extends StatelessWidget {
  const LetterAvatar({
    super.key,
    required this.name,
    this.radius = 24,
  });

  /// Display name used to pick the letter and color.
  final String name;

  /// Circle radius in logical pixels (defaults to 24 → 48dp diameter).
  final double radius;

  /// Fixed palette of distinct, readable colors for avatars.
  ///
  /// Hand-picked to ensure sufficient contrast with white text across
  /// both light and dark themes. Using a fixed palette rather than
  /// random HSL avoids accidentally generating colors that look muddy
  /// or clash with the app theme.
  static const _palette = [
    Color(0xFF1B8755), // green (brand)
    Color(0xFF3949AB), // indigo
    Color(0xFFE53935), // red
    Color(0xFF8E24AA), // purple
    Color(0xFFFF6F00), // amber
    Color(0xFF00838F), // cyan
    Color(0xFF4E342E), // brown
    Color(0xFF546E7A), // blue grey
    Color(0xFFC2185B), // pink
    Color(0xFF2E7D32), // dark green
  ];

  @override
  Widget build(BuildContext context) {
    // Use absolute value to avoid negative index from hashCode on certain
    // platforms. The modulo distributes contacts across the palette evenly.
    final colorIndex = name.hashCode.abs() % _palette.length;
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return CircleAvatar(
      radius: radius,
      backgroundColor: _palette[colorIndex],
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.85,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
