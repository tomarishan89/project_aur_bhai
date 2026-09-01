import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AurBhaiLogo extends StatelessWidget {
  /// Optional width of the logo.
  final double? width;

  /// Optional height of the logo.
  final double? height;

  /// If provided, overrides the theme color.
  final Color? color;

  const AurBhaiLogo({
    Key? key,
    this.width,
    this.height,
    this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // If no color is passed explicitly, it defaults to the primary color of the current theme.
    // This allows the logo to naturally adapt when switching themes in ThemeService.
    final themeColor = color ?? Theme.of(context).colorScheme.primary;

    return SvgPicture.asset(
      'assets/images/aur_bhai_logo.svg',
      width: width,
      height: height,
      colorFilter: ColorFilter.mode(
        themeColor,
        BlendMode.srcIn,
      ),
    );
  }
}
