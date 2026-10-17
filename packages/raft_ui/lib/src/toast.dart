import 'hover_region.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'design_primitives.dart' show RaftLayoutMetrics;
import 'dialog_card.dart';
import 'icons.dart';
import 'localization.dart';
import 'recipe_surface.dart';
import 'recipes/button_variants.g.dart';
import 'recipes/toast_styles.g.dart';
import 'theme.dart';

/// The mounted Web selection toast: inline, title-only, without an icon or
/// dismiss button (ChatPanel/ThreadPanel SELECTION_TOAST_OPTIONS). Paint comes
/// from raft-ui toastStyles; LocalizedToastProvider overrides title to normal
/// weight and permits wrapping. This is not the stacked/action toast variant.
class RaftToast extends StatelessWidget {
  const RaftToast({
    super.key,
    required this.title,
    this.description,
    this.tone = RaftToastRecipeTone.success,
    this.icon = false,
    this.onClose,
    this.actionLabel,
    this.onAction,
  });
  final String title;

  /// `toast.success(..., { action: { label, onClick } })`: a trailing text
  /// action (the follower removal toast's "Undo").
  final String? actionLabel;
  final VoidCallback? onAction;

  /// `ToastDescription` under the title (stacked in the same body column).
  final String? description;
  final RaftToastRecipeTone tone;

  /// LocalizedToastProvider default (`hasIcon !== false`): the tone glyph in a
  /// 20px `ToastIcon` cell before the body.
  final bool icon;

  /// `ToastClose` (default on toasts that keep their dismiss button): a 32px
  /// button in the trailing grid cell.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), rt = t.recipeTokens;
    final hasClose = onClose != null;
    final s = RaftToastRecipe.resolve(
      theme: t.recipeTheme,
      layout: RaftToastRecipeLayout.inline,
      tone: tone,
      states: t.recipeStates(
        extra: [
          if (icon)
            'has:data-slot=toast-icon'
          else
            'not:has:data-slot=toast-icon',
          if (hasClose)
            'has:data-slot=toast-actions'
          else
            'not:has:data-slot=toast-actions',
          if (description != null)
            'has:data-slot=toast-description'
          else
            'not:has:data-slot=toast-description',
        ],
      ),
      tokens: rt,
    );
    final titleStyle = s.title.text(rt).copyWith(fontWeight: FontWeight.w400);
    // Elegant (light) tone compound variants: `**:data-[slot=toast-icon]:
    // text-info / text-success / text-warning / text-brutal-red` (dark keeps
    // `text-foreground-muted`, brutal keeps `text-foreground-strong`).
    final iconColor = !t.brutal && !t.dark
        ? switch (tone) {
            RaftToastRecipeTone.info => t.colors['info'],
            RaftToastRecipeTone.success => t.colors['success'],
            RaftToastRecipeTone.warning => t.colors['warning'],
            RaftToastRecipeTone.error => t.product.brutalRed,
          }
        : null;
    final glyph = switch (tone) {
      RaftToastRecipeTone.success => RaftGlyph.checkCircle2,
      RaftToastRecipeTone.info => RaftGlyph.info,
      _ => RaftGlyph.alertTriangle,
    };
    // `!grid-cols-[auto_minmax(0,1fr)_auto] !gap-x-3`: three tracks, so the
    // two column gaps (24px) stay even when a track is empty.
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: titleStyle),
        if (description != null)
          Text(description!, style: s.description.text(rt)),
      ],
    );
    final Widget row = icon
        ? LayoutBuilder(
            // `grid-cols-[auto_minmax(0,1fr)_auto]`: when the content has a
            // min width (elegant `min-w-[18rem]`) the body track takes the
            // extra space and the close button stays at the trailing edge.
            builder: (context, c) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: Center(
                    child: RaftIcon(
                      glyph,
                      size: t.brutal ? 16 : 18,
                      // `[&_svg]:stroke-[2.5]` (brutal) / `stroke-[1.5]` (elegant).
                      strokeWidth: t.brutal ? 2.5 : 1.5,
                      color: iconColor ?? s.icon.textStyle(rt).color,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: actionLabel == null
                          ? math.max(
                              0,
                              c.minWidth - 20 - 12 - 12 - (hasClose ? 32 : 0),
                            )
                          : 0,
                    ),
                    child: body,
                  ),
                ),
                const SizedBox(width: 12),
                if (hasClose)
                  Semantics(
                    button: true,
                    label: raftText(context, 'Close'),
                    child: _ToastPaintSnap(
                      child: GestureDetector(
                        key: const Key('toast-close'),
                        onTap: onClose,
                        child: RaftRecipeBox(
                          style: s.close,
                          tokens: rt,
                          width: 32,
                          height: 32,
                          child: Center(
                            child: RaftIcon(
                              RaftGlyph.x,
                              size: 14,
                              color: s.close.textStyle(rt).color,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (actionLabel != null) ...[
                  if (hasClose) const SizedBox(width: 4),
                  RaftRecipeButton(
                    key: const Key('toast-action'),
                    variant: RaftButtonRecipeVariant.outline,
                    size: RaftButtonRecipeSize.sm,
                    label: actionLabel,
                    onPressed: onAction,
                  ),
                ],
              ],
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: body),
              if (actionLabel != null) ...[
                const SizedBox(width: 12),
                RaftRecipeButton(
                  key: const Key('toast-action'),
                  variant: RaftButtonRecipeVariant.outline,
                  size: RaftButtonRecipeSize.sm,
                  label: actionLabel,
                  onPressed: onAction,
                ),
              ],
              const SizedBox(width: 24),
            ],
          );
    Widget root = RaftRecipeBox(
      style: s.root,
      tokens: rt,
      child: RaftRecipeBox(
        style: s.content,
        tokens: rt,
        child: _ToastSnapWidth(child: row),
      ),
    );
    // Elegant root `saturate-150` (`dark:saturate-100`): a CSS filter over the
    // whole toast (fill, icon and text), standard sRGB saturate matrix.
    if (!t.brutal && !t.dark) {
      root = ColorFiltered(colorFilter: _saturate(1.5), child: root);
    }
    // The host's overlay sits above the router, outside any Material or
    // Scaffold, where the WidgetsApp fallback text style (yellow double
    // underline, monospace) would reach every unstyled Text. Give the toast
    // its own base so it renders the same from any context.
    return DefaultTextStyle(
      style: titleStyle.copyWith(decoration: TextDecoration.none),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: _ToastPaintSnap(child: root),
      ),
    );
  }
}

/// Blink lays a `w-max` box out at its fractional width but snaps the painted
/// edges (and so every border) to whole device pixels: the content width
/// rounds up to a whole pixel here so the root and the close button borders stay
/// crisp like Web.
class _ToastSnapWidth extends SingleChildRenderObjectWidget {
  const _ToastSnapWidth({required Widget super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderToastSnapWidth();
}

class _RenderToastSnapWidth extends RenderProxyBox {
  @override
  void performLayout() {
    final c = child!;
    c.layout(constraints, parentUsesSize: true);
    final width = c.size.width;
    final snapped = width.ceilToDouble();
    if (snapped != width && constraints.isTight == false) {
      c.layout(
        constraints.copyWith(
          minWidth: constraints.constrainWidth(snapped),
          maxWidth: constraints.constrainWidth(snapped),
        ),
        parentUsesSize: true,
      );
    }
    size = c.size;
  }
}

/// Paints its child at the whole CSS pixel (round half up) of its global
/// origin, like Blink's pixel-snapped box painting.
class _ToastPaintSnap extends SingleChildRenderObjectWidget {
  const _ToastPaintSnap({required Widget super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderToastPaintSnap();
}

class _RenderToastPaintSnap extends RenderProxyBox {
  Offset _delta = Offset.zero;

  Offset _snap() {
    if (!attached) return Offset.zero;
    final origin = localToGlobal(Offset.zero);
    double round(double v) => (v + .5).floorToDouble() - v;
    return Offset(round(origin.dx), round(origin.dy));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _delta = _snap();
    super.paint(context, offset + _delta);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_delta.dx, _delta.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _delta,
        position: position,
        hitTest: (result, transformed) =>
            super.hitTestChildren(result, position: transformed),
      );
}

/// CSS `saturate(amount)` as a colour matrix.
ColorFilter _saturate(double a) => ColorFilter.matrix([
  0.213 + 0.787 * a,
  0.715 - 0.715 * a,
  0.072 - 0.072 * a,
  0,
  0,
  0.213 - 0.213 * a,
  0.715 + 0.285 * a,
  0.072 - 0.072 * a,
  0,
  0,
  0.213 - 0.213 * a,
  0.715 - 0.715 * a,
  0.072 + 0.928 * a,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

/// UI-owned transient feedback. No payload persistence or app/API dependency.
/// A new notice replaces this owner's old notice and restarts its timeout.
class RaftToastController extends ChangeNotifier {
  Timer? _timer;
  DateTime? _started;
  Duration _remaining = Duration.zero;
  bool _paused = false;
  String? _title;
  String? get title => _title;
  String? _actionLabel;
  VoidCallback? _onAction;
  String? get actionLabel => _actionLabel;
  VoidCallback? get onAction => _onAction;
  RaftToastRecipeTone _tone = RaftToastRecipeTone.success;
  RaftToastRecipeTone get tone => _tone;
  bool _dismissible = true;
  bool get dismissible => _dismissible;

  // Surfaces a narrow-layout toast must clear (the composer). Registered by
  // the surface, read by the portal each build.
  final Map<GlobalKey, bool Function()> _avoided = {};

  /// Keeps a narrow-layout toast above the box [key] is attached to while
  /// [active] is true (a covered route's composer does not count).
  void avoid(GlobalKey key, bool Function() active) {
    _avoided[key] = active;
  }

  void unavoid(GlobalKey key) {
    _avoided.remove(key);
  }

  /// Top edge, in [overlay]'s coordinates, of the highest avoided surface, or
  /// null when none is on screen.
  double? avoidedTop(RenderBox overlay) {
    double? top;
    for (final entry in _avoided.entries) {
      final box = entry.key.currentContext?.findRenderObject();
      if (!entry.value() ||
          box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          !overlay.attached) {
        continue;
      }
      final y = overlay.globalToLocal(box.localToGlobal(Offset.zero)).dy;
      if (y < overlay.size.height && (top == null || y < top)) top = y;
    }
    return top;
  }

  /// raft-ui ToastProvider's authored default is 5000ms.
  void show(
    String title, {
    Duration duration = const Duration(seconds: 5),
    String? actionLabel,
    VoidCallback? onAction,
    RaftToastRecipeTone tone = RaftToastRecipeTone.success,

    /// LocalizedToastProvider `hasClose` (shown unless `data.hasClose` is
    /// false; only the selection and Forward toasts opt out).
    bool dismissible = true,
  }) {
    _timer?.cancel();
    _dismissible = dismissible;
    _title = title;
    _actionLabel = actionLabel;
    _onAction = onAction;
    _tone = tone;
    _remaining = duration;
    if (!_paused) _start();
    notifyListeners();
  }

  void _start() {
    _started = DateTime.now();
    _timer = Timer(_remaining, clear);
  }

  void pause(bool value) {
    if (_paused == value) return;
    _paused = value;
    if (_title == null) return;
    if (value) {
      _timer?.cancel();
      final elapsed = DateTime.now().difference(_started!);
      _remaining = _remaining - elapsed;
      if (_remaining.isNegative) _remaining = Duration.zero;
    } else {
      _start();
    }
  }

  void clear() {
    _timer?.cancel();
    if (_title == null) return;
    _title = null;
    _actionLabel = null;
    _onAction = null;
    _paused = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _title = null;
    super.dispose();
  }
}

/// Scoped portal: inherits the owner's theme and disappears with its widget.
/// Matches the bottom-center viewport: min(24rem, viewport - 2rem), bottom 16.
/// Safe-area/keyboard insets protect native system chrome without moving the
/// underlying layout or capturing focus. Hover/focus pauses the timeout.
class RaftToastPortal extends StatefulWidget {
  const RaftToastPortal({
    super.key,
    required this.controller,
    this.child = const SizedBox.shrink(),
  });
  final RaftToastController controller;
  final Widget child;
  @override
  State<RaftToastPortal> createState() => _RaftToastPortalState();
}

class _RaftToastPortalState extends State<RaftToastPortal> {
  final portal = OverlayPortalController();
  bool hovered = false, focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    if (widget.controller.title != null) portal.show();
  }

  void changed() {
    if (widget.controller.title == null) {
      hovered = focused = false;
      portal.hide();
    } else {
      portal.show();
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RaftToastPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(changed);
      oldWidget.controller.pause(false);
      widget.controller.addListener(changed);
      widget.controller.pause(hovered || focused);
      changed();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    // Only this owner's controller is affected, never another toast host.
    widget.controller.pause(false);
    super.dispose();
  }

  /// Narrow layouts (below the Web `md` breakpoint) lift the toast above the
  /// composer instead of over its input and send button. Web's bottom-center
  /// viewport has no such offset; wide layouts keep it exactly. Measured from
  /// the composer's last layout, then re-measured once the frame settles
  /// (keyboard, a new attachment strip).
  double composerClearance(BuildContext context) {
    double measure() {
      if (MediaQuery.sizeOf(context).width >=
          RaftLayoutMetrics.desktopBreakpoint) {
        return 0;
      }
      final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
      if (overlay is! RenderBox || !overlay.hasSize) return 0;
      final top = widget.controller.avoidedTop(overlay);
      return top == null ? 0 : overlay.size.height - top + 8;
    }

    final clearance = measure();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.mounted && (measure() - clearance).abs() > .5) {
        setState(() {});
      }
    });
    return clearance;
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: portal,
    overlayChildBuilder: (context) {
      final m = MediaQuery.of(context);
      final title = widget.controller.title;
      if (title == null) return const SizedBox.shrink();
      return Positioned(
        bottom: math.max(
          16 + math.max(m.padding.bottom, m.viewInsets.bottom),
          composerClearance(context),
        ),
        left: 16 + m.padding.left,
        right: 16 + m.padding.right,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 384),
            child: Focus(
              onFocusChange: (value) {
                focused = value;
                widget.controller.pause(hovered || focused);
              },
              child: RaftHoverRegion(
                onEnter: (_) {
                  hovered = true;
                  widget.controller.pause(true);
                },
                onExit: (_) {
                  hovered = false;
                  widget.controller.pause(focused);
                },
                child: RaftToast(
                  title: title,
                  tone: widget.controller.tone,
                  // LocalizedToastProvider: the icon and the close button are
                  // both on by default; the selection toast drops both.
                  icon: widget.controller.dismissible,
                  onClose: widget.controller.dismissible
                      ? widget.controller.clear
                      : null,
                  actionLabel: widget.controller.actionLabel,
                  onAction: () {
                    final action = widget.controller.onAction;
                    widget.controller.clear();
                    action?.call();
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
    child: widget.child,
  );
}
