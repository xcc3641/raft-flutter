import 'hover_region.dart';

import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_primitives.dart' show RaftTypography;
import 'icons.dart';
import 'list_items.dart';
import 'recipe_surface.dart';
import 'recipes/context_menu.g.dart';
import 'recipes/token_binding.dart';
import 'theme.dart';

/// One entry of a Sidebar.tsx `ContextMenuPopup`: a `MenuItem` row, the small
/// uppercase group heading above the sort / display rows, or a
/// `ContextMenuDivider`.
@immutable
sealed class RaftSidebarMenuEntry {
  const RaftSidebarMenuEntry();
}

class RaftSidebarMenuItem extends RaftSidebarMenuEntry {
  const RaftSidebarMenuItem({
    required this.label,
    this.glyph,
    this.onPressed,
    this.checked = false,
    this.submenu = false,
    this.onHover,
    this.itemKey,
  });
  final String label;

  /// 14px lucide icon before the label (`icon={<Plus size={14} />}`).
  final RaftGlyph? glyph;
  final VoidCallback? onPressed;

  /// Trailing `<Check size={14} />` of the checked radio / checkbox rows.
  final bool checked;

  /// Trailing `<ChevronRight size={14} />` of "Move to section".
  final bool submenu;
  final VoidCallback? onHover;
  final Key? itemKey;
}

class RaftSidebarMenuHeading extends RaftSidebarMenuEntry {
  const RaftSidebarMenuHeading(this.label);
  final String label;
}

class RaftSidebarMenuDivider extends RaftSidebarMenuEntry {
  const RaftSidebarMenuDivider();
}

/// Sidebar.tsx row / section / surface context menu and the "Move to section"
/// submenu: raft-ui `ContextMenuPopup` (the message menu recipe) at a fixed
/// width (`w-48` rows, `w-64` sections, `w-56` submenu).
class RaftSidebarContextMenu extends StatefulWidget {
  const RaftSidebarContextMenu({
    super.key,
    required this.entries,
    this.width = 192,
    this.onDismiss,
    this.label,
    this.submenuEntries,
    this.submenuWidth = 224,
    this.submenuLabel,
  });
  final List<RaftSidebarMenuEntry> entries;
  final double width;
  final VoidCallback? onDismiss;
  final String? label;

  /// "Move to section": opened by hovering / pressing the `submenu: true` row,
  /// closed by hovering any other row (Sidebar.tsx `moveToSectionMenuOpen`).
  final List<RaftSidebarMenuEntry>? submenuEntries;
  final double submenuWidth;
  final String? submenuLabel;

  @override
  State<RaftSidebarContextMenu> createState() => _RaftSidebarContextMenuState();
}

class _RaftSidebarContextMenuState extends State<RaftSidebarContextMenu> {
  bool submenuOpen = false;
  final mainKey = GlobalKey();
  final portal = OverlayPortalController();

  void setOpen(bool open) {
    if (open == submenuOpen) return;
    setState(() => submenuOpen = open);
    open ? portal.show() : portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final menu = KeyedSubtree(
      key: mainKey,
      child: _menu(
        context,
        widget.entries,
        widget.width,
        widget.label,
        primary: true,
      ),
    );
    final sub = widget.submenuEntries;
    if (sub == null) return menu;
    return OverlayPortal(
      controller: portal,
      overlayChildBuilder: (overlayContext) =>
          _submenu(overlayContext, context, sub),
      child: menu,
    );
  }

  /// Sidebar.tsx `placeSidebarContextSubmenu`: a second popup (`w-56`, z 51)
  /// level with the trigger row, 4px right of the main menu, else 4px left of
  /// it, never closer than 8px to the viewport edge - on a phone it therefore
  /// covers the main menu.
  Widget _submenu(
    BuildContext overlayContext,
    BuildContext menuContext,
    List<RaftSidebarMenuEntry> sub,
  ) {
    final main = mainKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(overlayContext).context.findRenderObject();
    if (main is! RenderBox ||
        !main.attached ||
        overlay is! RenderBox ||
        !overlay.attached) {
      return const SizedBox.shrink();
    }
    final t = RaftTokens.of(menuContext);
    final content = RaftContextMenuRecipe.resolve(
      theme: t.recipeTheme,
      states: t.recipeStates(),
      tokens: RaftRecipeTokens(t),
    ).content;
    final origin = main.localToGlobal(Offset.zero, ancestor: overlay);
    return CustomSingleChildLayout(
      delegate: _SubmenuLayout(
        left: origin.dx,
        right: origin.dx + main.size.width,
        // The trigger row's top: below the popup's border and padding.
        top: origin.dy + content.borderWidth.top + content.padding.top,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: _menu(
          menuContext,
          sub,
          widget.submenuWidth,
          widget.submenuLabel,
        ),
      ),
    );
  }

  Widget _menu(
    BuildContext context,
    List<RaftSidebarMenuEntry> entries,
    double width,
    String? label, {
    bool primary = false,
  }) {
    final t = RaftTokens.of(context);
    final resolver = RaftRecipeTokens(t);
    final s = RaftContextMenuRecipe.resolve(
      theme: t.recipeTheme,
      states: t.recipeStates(),
      tokens: resolver,
    );
    final content = s.content;
    final separator = s.separator;
    Widget divider() {
      final w = separator.borderWidth.top;
      final m = separator.margin;
      final color = w > 0
          ? separator
                .borderColorOf('top')
                ?.resolve(resolver, currentColor: t.strong)
          : separator.backgroundColor?.resolve(resolver);
      return Padding(
        padding: EdgeInsets.only(top: m.top, bottom: m.bottom),
        child: CustomPaint(
          size: Size(0, w > 0 ? w : (separator.height ?? 1)),
          painter: _Rule(color ?? t.strong, left: m.left, right: m.right),
        ),
      );
    }

    final children = <Widget>[
      for (final entry in entries)
        switch (entry) {
          RaftSidebarMenuDivider() => divider(),
          RaftSidebarMenuHeading(:final label) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              label.toUpperCase(),
              style:
                  RaftTypography.heading(
                    t,
                    size: 10,
                    line: 15,
                    weight: FontWeight.w700,
                  ).copyWith(
                    letterSpacing: 1.5,
                    color: t.brutal
                        ? Colors.black.withValues(alpha: .5)
                        : t.colors['foreground-muted'],
                  ),
            ),
          ),
          RaftSidebarMenuItem() => RaftHoverRegion(
            onEnter: (_) {
              if (primary) setOpen(entry.submenu);
              entry.onHover?.call();
            },
            child: RaftMenuButtonItem(
              key: entry.itemKey,
              label: entry.label,
              icon: entry.glyph == null
                  ? null
                  : SizedBox.square(
                      dimension: 14,
                      child: RaftIcon(
                        entry.glyph!,
                        size: 14,
                        color: IconTheme.of(context).color,
                      ),
                    ),
              trailing: entry.checked
                  ? const RaftIcon(RaftGlyph.check, size: 14)
                  : entry.submenu
                  ? const RaftIcon(RaftGlyph.chevronRight, size: 14)
                  : null,
              onPressed: entry.submenu
                  ? () => setOpen(true)
                  : (entry.onPressed ?? () {}),
            ),
          ),
        },
    ];
    final gap = content.rowGap ?? 0;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.onDismiss?.call(),
      },
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Semantics(
          role: SemanticsRole.menu,
          label: label,
          child: SizedBox(
            width: width,
            child: RaftRecipeBox(
              style: content,
              tokens: resolver,
              clip: true,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0 && gap > 0) SizedBox(height: gap),
                      children[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Rule extends CustomPainter {
  const _Rule(this.color, {this.left = 0, this.right = 0});
  final Color color;
  final double left, right;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    Rect.fromLTRB(left, 0, size.width - right, size.height),
    Paint()..color = color,
  );
  @override
  bool shouldRepaint(_Rule old) =>
      old.color != color || old.left != left || old.right != right;
}

class _SubmenuLayout extends SingleChildLayoutDelegate {
  const _SubmenuLayout({
    required this.left,
    required this.right,
    required this.top,
  });
  final double left, right, top;
  static const margin = 8.0, gap = 4.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(0, constraints.maxWidth - margin * 2),
          math.max(0, constraints.maxHeight - margin * 2),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightX = right + gap;
    final x = rightX + childSize.width <= size.width - margin
        ? rightX
        : math.max(margin, left - childSize.width - gap);
    final maxY = math.max(margin, size.height - childSize.height - margin);
    return Offset(x, top.clamp(margin, maxY).toDouble());
  }

  @override
  bool shouldRelayout(_SubmenuLayout old) =>
      old.left != left || old.right != right || old.top != top;
}
