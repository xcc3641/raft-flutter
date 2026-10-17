import 'hover_region.dart';

import 'package:flutter/material.dart';

/// Web SenderAvatar `<button>`: `transition-[filter,transform] duration-75
/// hover:brightness-90`, scaled to .9 and darkened (`brightness-75`) while
/// pressed. The artwork stays the caller's.
class RaftAvatarButton extends StatefulWidget {
  const RaftAvatarButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.semanticLabel,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  State<RaftAvatarButton> createState() => _RaftAvatarButtonState();
}

class _RaftAvatarButtonState extends State<RaftAvatarButton> {
  bool hovered = false, pressed = false;

  /// CSS `brightness(x)`: scale the colour channels.
  static ColorFilter brightness(double v) => ColorFilter.matrix([
    v, 0, 0, 0, 0, //
    0, v, 0, 0, 0, //
    0, 0, v, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    Widget child = widget.child;
    if (enabled && (hovered || pressed)) {
      child = ColorFiltered(
        colorFilter: brightness(pressed ? .75 : .9),
        child: child,
      );
    }
    if (enabled && pressed) {
      child = Transform.scale(scale: .9, child: child);
    }
    return Semantics(
      button: enabled,
      label: widget.semanticLabel,
      child: RaftHoverRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          onTapDown: enabled ? (_) => setState(() => pressed = true) : null,
          onTapUp: (_) => setState(() => pressed = false),
          onTapCancel: () => setState(() => pressed = false),
          child: ExcludeSemantics(child: child),
        ),
      ),
    );
  }
}
