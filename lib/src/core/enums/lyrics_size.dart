// ORPHEUS: text size of the lyrics view, as a factor of the default size.
enum LyricsSize {
  small(0.85),
  medium(1),
  large(1.2),
  extraLarge(1.4);

  const LyricsSize(this.scale);

  final double scale;
}
