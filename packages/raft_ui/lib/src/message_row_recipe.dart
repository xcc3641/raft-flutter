import 'hover_region.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'design_primitives.dart';
import 'font_warm_up.dart';
import 'localization.dart';
import 'message_semantics.dart';
import 'pointer_intent.dart';
import 'viewport_breakpoints.dart';
import 'tokens/tokens.dart';
import 'css_border.dart';
import 'text_scaling.dart' show RaftScaled;
import 'theme.dart';
import 'tooltip.dart' show RaftTooltip;
import 'recipe_surface.dart' show RaftCssBoxDecoration;

/// ThreadPanelContent applies its own descendant padding below lg.
enum RaftMessageRowContext { main, thread }

/// Pinned raft-ui 0.5.27 MessageItem plus mounted MessageItem.tsx overrides.
/// The adapter owns identity, grouping, pointer capability, and permissions.
@immutable
class RaftMessageRowRecipe {
  const RaftMessageRowRecipe(
    this.tokens, {
    required this.viewportWidth,
    this.rowContext = RaftMessageRowContext.main,
    this.continuation = false,
    this.nextContinuation = false,
    this.hovered = false,
    this.focused = false,
    this.popupOpen = false,
    this.highlighted = false,
    this.devicePixelRatio = 1,
  });
  final RaftTokens tokens;
  final double viewportWidth;

  /// For Blink's whole-device-pixel border widths ([raftCssBorderWidth]).
  final double devicePixelRatio;
  final RaftMessageRowContext rowContext;
  final bool continuation, nextContinuation, hovered, focused, popupOpen;
  final bool highlighted;
  bool get mobile => viewportWidth < 768;
  double get horizontalPadding =>
      rowContext == RaftMessageRowContext.thread && viewportWidth < 1024
      ? 12
      : mobile
      ? 16
      : 28;
  bool get attention => hovered || popupOpen;
  bool get toolbarVisible => hovered || focused || popupOpen;
  double get borderWidth => tokens.brutal ? 2 : 1;
  double get minimumHeight => continuation ? 0 : 48;
  EdgeInsets get margin => tokens.brutal
      ? EdgeInsets.fromLTRB(12, continuation ? 0 : 6, 12, 4)
      : EdgeInsets.zero;
  EdgeInsets get padding => tokens.brutal
      ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
      : EdgeInsets.fromLTRB(
          horizontalPadding,
          continuation
              ? 6
              : mobile
              ? 8
              : 14,
          horizontalPadding,
          continuation
              ? 6
              : nextContinuation
              ? (mobile ? 0 : 2)
              : (mobile ? 6 : 12),
        );
  double get gutterWidth => tokens.brutal || !mobile ? 36 : 32;
  double get avatarExtent => 36; // AvatarSlot(panel-header): !size-9 !border-2.
  double get avatarTop =>
      2; // MessageSenderAvatar: mt-0.5; flex slot avoids baseline drift.
  double get gap => tokens.brutal || !mobile ? 12 : 8;
  double get headerReserve => 96;
  double get headerGap => tokens.brutal ? 8 : 6;
  double get headerLine => tokens.brutal ? 20 : 21;
  double get bodyGap => tokens.brutal || continuation
      ? 0
      : mobile
      ? 4
      : 6;
  double get attachmentGap => 4;
  double get translationLine => tokens.brutal ? 20 : 21;
  // Baseline alignment puts the status' centre just above the line's centre.
  double get translationLift => tokens.brutal ? 2.6 : 1;
  double get footerGap =>
      6; // Mounted MessageItemFooter overrides generic Elegant desktop mt10.
  double get toolbarTop => tokens.brutal ? -14 : 4;
  double get toolbarRight => tokens.brutal ? 8 : 29;
  double get toolbarButtonExtent => tokens.brutal ? 24 : 28;
  double get toolbarGap => tokens.brutal ? 0 : 2;
  EdgeInsets get toolbarPadding => tokens.brutal
      ? EdgeInsets.zero
      : const EdgeInsets.symmetric(horizontal: 4, vertical: 2);
  Color get background => highlighted
      ? tokens.colors[tokens.brutal ? 'color-brutal-cyan' : 'info']!.withValues(
          alpha: tokens.brutal ? .25 : .1,
        )
      : attention
      ? (tokens.brutal ? tokens.panel : tokens.colors['ink-2']!)
      : Colors.transparent;
  Color get border => tokens.brutal && attention
      ? (popupOpen ? RaftPrimitiveColors.black : tokens.strong)
      : Colors.transparent;
  TextStyle get body => TextStyle(
    locale: tokens.textLocale,
    // Mounted host uses font-display, not Elegant's generic font-sans (Geist).
    fontFamily: tokens.headingFont,
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: tokens.brutal ? 0 : -.14,
    color: tokens.brutal ? RaftPrimitiveColors.black : tokens.muted,
  );
  TextStyle get author => body.copyWith(
    height: tokens.brutal ? 20 / 14 : 1,
    fontWeight: tokens.brutal ? FontWeight.w700 : FontWeight.w500,
  );
  TextStyle get time => TextStyle(
    locale: tokens.textLocale,
    fontFamily: tokens.brutal ? tokens.monoFont : tokens.bodyFont,
    fontSize: 12,
    height: tokens.brutal ? 16 / 12 : 1,
    letterSpacing: tokens.brutal ? 0 : -.14,
    color: tokens.brutal
        ? RaftPrimitiveColors.black.withValues(alpha: .4)
        : tokens.muted.withValues(alpha: tokens.muted.a * .7),
  );
  TextStyle get continuationTime => TextStyle(
    locale: tokens.textLocale,
    fontFamily: tokens.monoFont,
    fontSize: 10,
    height: 1,
    color: hovered
        ? (tokens.brutal
              ? RaftPrimitiveColors.black.withValues(alpha: .4)
              : tokens.colors['foreground-placeholder']!)
        : Colors.transparent,
  );
  // The focus fill is translucent and the idle fill transparent: the brutal
  // shadow must paint outside the border box only (CSS `box-shadow`), never
  // through the fill as Flutter's BoxDecoration shadow does.
  BoxDecoration get decoration => RaftCssBoxDecoration(
    color: background,
    border: Border.all(color: border, width: borderWidth),
    boxShadow: tokens.brutal && (highlighted || popupOpen)
        // Mounted index.css91–92 overrides the generic RUI elevation.
        ? (highlighted
                  ? RaftProductShadows.shadowBrutal
                  : RaftProductShadows.shadowBrutalSm)
              .outer
        : null,
  );
  BoxDecoration? get highlightRing => highlighted
      ? BoxDecoration(
          border: Border.all(
            color: tokens.colors['info']!.withValues(alpha: .5),
            width: 1,
          ),
        )
      : null;
  BoxDecoration get toolbarDecoration => BoxDecoration(
    color: tokens.panel,
    border: Border.all(
      color: tokens.brutal
          ? tokens.strong
          : tokens.dark
          ? Colors.transparent
          : tokens.colors['line-muted']!,
      width: tokens.brutal ? 2 : raftCssBorderWidth(.5, devicePixelRatio),
    ),
    borderRadius: BorderRadius.circular(tokens.brutal ? 0 : 8),
    boxShadow: tokens.brutal || tokens.dark
        ? tokens.shadows
        : const [
            // foundation.css360: --theme-shadow-xs, original OKLCH atom resolved to sRGB.
            BoxShadow(color: Color(0x120a0a09), offset: Offset(0, .5)),
          ],
  );
}

/// Controlled mounted row. No message model, cache, API, or authority lookup.
/// Active toolbars remain hit-testable above their row, inside its viewport.
/// The message body's own vertical margin (`mt-1.5 mb-1.5`). A block that is
/// the body's first child with its own top margin (the action card's `mt-1`)
/// collapses with it: the gap is the larger of the two, not their sum.
class RaftMessageBodyMargin extends InheritedWidget {
  const RaftMessageBodyMargin({
    super.key,
    required this.gap,
    required super.child,
  });
  final double gap;

  /// Top margin left to add for a child that has [margin] of its own.
  static double collapse(BuildContext context, double margin) {
    final scope = context
        .getInheritedWidgetOfExactType<RaftMessageBodyMargin>();
    return scope == null ? margin : (margin - scope.gap).clamp(0.0, margin);
  }

  @override
  bool updateShouldNotify(RaftMessageBodyMargin old) => gap != old.gap;
}

/// A last block that is a *sibling* of the Web message body (the quoted
/// message card): the body's own bottom margin collapses into the block's
/// `mt-*`, so nothing follows the block. Flutter pads the whole content, so
/// the block bleeds into that bottom padding by the body margin.
class RaftBodyTrailingBleed extends SingleChildRenderObjectWidget {
  const RaftBodyTrailingBleed({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTrailingBleed(_bleedOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTrailingBleed renderObject,
  ) => renderObject.bleed = _bleedOf(context);

  static double _bleedOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<RaftMessageBodyMargin>()?.gap ?? 0;
}

class _RenderTrailingBleed extends RenderProxyBox {
  _RenderTrailingBleed(this._bleed);
  double _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = Size(
      child.size.width,
      (child.size.height - _bleed).clamp(0.0, child.size.height),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;

  @override
  bool hitTestSelf(Offset position) => false;
}

class RaftMessageRow extends StatefulWidget {
  const RaftMessageRow({
    super.key,
    required this.author,
    required this.timestamp,
    required this.content,
    this.continuationTimestamp,
    this.timestampTooltip,
    this.avatar,
    this.metadata,
    this.subtitle,
    this.attachments,
    this.translation,
    this.footer,
    this.inlineReplies,
    this.toolbar,
    this.selectionLeading,
    this.onAuthor,
    this.onActions,
    this.onActionsAt,
    this.onTap,
    this.rowContext = RaftMessageRowContext.main,
    this.continuation = false,
    this.nextContinuation = false,
    this.coarsePointer = false,
    this.popupOpen = false,
    this.highlighted = false,
    this.semanticsLabel,
    this.semanticsText = '',
    this.semanticsActions = const [],
  });
  final String author, timestamp;

  /// Clock-only label for the narrow continuation gutter. The complete
  /// [timestamp] remains available to the header and accessibility label.
  final String? continuationTimestamp;

  /// Complete date and time, shown when the continuation clock is hovered.
  final String? timestampTooltip;
  final RaftMessageRowContext rowContext;

  /// Compact accessibility: when set (e.g. "Alice, 10:01 AM"), the row is one
  /// semantics node labelled with it and [semanticsText]. Header and avatar
  /// are excluded, [semanticsActions] become custom actions and long press
  /// opens the message menu. See [RaftMessageSemanticsScope].
  final String? semanticsLabel;
  final String semanticsText;
  final List<RaftMessageSemanticsAction> semanticsActions;
  final Widget content;
  final Widget? avatar, metadata, attachments, footer, inlineReplies, toolbar;

  /// Web MessageItem translation status (`mt-0`): after the attachments,
  /// before the footer.
  final Widget? translation;

  /// Web MessageItem multi-select checkbox: first flex child of the row
  /// (`self-start mt-1.5`, `gap` before the avatar gutter).
  final Widget? selectionLeading;
  final String? subtitle;
  final VoidCallback? onAuthor, onActions, onTap;

  /// Web MessageItem opens its context menu at the pointer: right-click
  /// (`contextmenu` clientX/Y) and 500ms long-press (touch clientX/Y).
  /// Receives the global press position; takes precedence over [onActions].
  final ValueChanged<Offset>? onActionsAt;
  final bool continuation,
      nextContinuation,
      coarsePointer,
      popupOpen,
      highlighted;
  @override
  State<RaftMessageRow> createState() => _RaftMessageRowState();
}

class _RaftMessageRowState extends State<RaftMessageRow> {
  bool hovered = false, toolbarHovered = false, focused = false;
  bool scrollSuppressed = false;
  bool secondaryDown = false;
  final portal = OverlayPortalController();
  final toolbarKey = GlobalKey();

  /// Idle rows do not build their action strip. This node holds the strip's
  /// place in keyboard traversal; focusing it reveals the strip and hands
  /// focus to its first (Tab) or last (Shift+Tab) action.
  late final toolbarProxy = FocusNode(debugLabel: 'message toolbar')
    ..addListener(toolbarProxyChanged);
  final toolbarGroup = FocusNode(
    debugLabel: 'message toolbar actions',
    canRequestFocus: false,
    skipTraversal: true,
  );
  ScrollPosition? position, listeningPosition;
  double? listeningOffset;
  bool listeningScrollSignal = false;
  bool portalSyncQueued = false;
  bool tickerEnabled = true, portalMounted = false;
  final visibleFraction = ValueNotifier<double?>(null);
  bool get toolbarActive =>
      tickerEnabled &&
      !scrollSuppressed &&
      !widget.coarsePointer &&
      widget.toolbar != null &&
      (hovered || toolbarHovered || focused || widget.popupOpen);

  @override
  void initState() {
    super.initState();
    RaftPointerIntent.install();
    if (toolbarActive) portal.show();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the list's remaining font combinations while it is idle.
    RaftFontWarmUp.schedule(context);
    position = Scrollable.maybeOf(context)?.position;
    tickerEnabled = TickerMode.valuesOf(context).enabled;
    syncPortal();
  }

  void syncPortal() {
    final active = toolbarActive;
    if (active != listeningScrollSignal) {
      listeningScrollSignal = active;
      if (active) {
        RaftPointerIntent.listenScroll(retireForScroll);
      } else {
        RaftPointerIntent.unlistenScroll(retireForScroll);
      }
    }
    final next = active ? position : null;
    if (!identical(next, listeningPosition)) {
      listeningPosition?.removeListener(scrollChanged);
      listeningPosition = next;
      listeningOffset = next?.pixels;
      listeningPosition?.addListener(scrollChanged);
    }
    if (active == portal.isShowing) return;
    // Parent property/TickerMode changes can occur during build. Pointer and
    // focus events update immediately; dependency updates retire after layout.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (portalSyncQueued) return;
      portalSyncQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        portalSyncQueued = false;
        if (mounted) syncPortal();
      });
      return;
    }
    if (active) {
      portal.show();
    } else {
      portal.hide();
    }
  }

  void attentionChanged(VoidCallback update) {
    setState(update);
    syncPortal();
  }

  void retireForScroll() {
    if (!mounted || !toolbarActive) return;
    // The old floating strip must retire before a retained row leaves the
    // viewport. Its portal anchor is then culled from native semantics.
    attentionChanged(() {
      hovered = false;
      toolbarHovered = false;
      scrollSuppressed = true;
    });
  }

  void scrollChanged() {
    final pixels = listeningPosition?.pixels;
    if (pixels == listeningOffset) return;
    listeningOffset = pixels;
    RaftPointerIntent.scrolled();
    retireForScroll();
    // Retire focused strips too: a kept-alive row has no paint transform once
    // it leaves the viewport. Fresh keyboard focus can reopen its actions.
  }

  @override
  void didUpdateWidget(covariant RaftMessageRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.coarsePointer) hovered = toolbarHovered = false;
    if (widget.toolbar == null) toolbarHovered = false;
    if (widget.popupOpen && !oldWidget.popupOpen) scrollSuppressed = false;
    syncPortal();
  }

  @override
  void dispose() {
    listeningPosition?.removeListener(scrollChanged);
    if (listeningScrollSignal) {
      RaftPointerIntent.unlistenScroll(retireForScroll);
    }
    toolbarProxy.dispose();
    toolbarGroup.dispose();
    visibleFraction.dispose();
    super.dispose(); // OverlayPortal removes its owned overlay on unmount.
  }

  void toolbarProxyChanged() {
    if (!toolbarProxy.hasPrimaryFocus) return;
    // The offstage proxy has zero height. Default focus traversal can reveal
    // only its top point at the bottom edge, leaving the whole row clipped.
    // Reveal the actual row before opening its portal and moving action focus.
    Scrollable.ensureVisible(
      context,
      alignment: 1,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    if (scrollSuppressed) attentionChanged(() => scrollSuppressed = false);
    final backward = HardwareKeyboard.instance.isShiftPressed;
    // The row's focus listener has already revealed the strip; its actions
    // exist after the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !toolbarProxy.hasPrimaryFocus) return;
      final actions = toolbarGroup.traversalDescendants.toList();
      if (actions.isNotEmpty) {
        (backward ? actions.last : actions.first).requestFocus();
      } else if (backward) {
        toolbarProxy.previousFocus(); // Every action is inert (pending row).
      } else {
        toolbarProxy.nextFocus();
      }
    });
  }

  Widget overlay(
    BuildContext overlayContext,
    OverlayChildLayoutInfo info,
    RaftMessageRowRecipe recipe,
  ) {
    var viewport = Offset.zero & info.overlaySize;
    final scrollBox = Scrollable.maybeOf(context)?.context.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (scrollBox is RenderBox &&
        scrollBox.hasSize &&
        overlayBox is RenderBox) {
      viewport = viewport.intersect(
        MatrixUtils.transformRect(
          scrollBox.getTransformTo(overlayBox),
          Offset.zero & scrollBox.size,
        ),
      );
    }
    final row = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    if (!row.isFinite ||
        row.width <= 0 ||
        row.bottom <= viewport.top ||
        row.top >= viewport.bottom) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: ClipRect(
        clipper: _MessageToolbarClip(viewport),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: row.top + recipe.toolbarTop,
              right: info.overlaySize.width - row.right + recipe.toolbarRight,
              child: RaftHoverRegion(
                onEnter: (_) {
                  if (!toolbarHovered)
                    attentionChanged(() => toolbarHovered = true);
                },
                onExit: (_) {
                  if (toolbarHovered)
                    attentionChanged(() => toolbarHovered = false);
                },
                child: ExcludeSemantics(
                  excluding: !recipe.toolbarVisible,
                  child: IgnorePointer(
                    ignoring: !recipe.toolbarVisible,
                    child: Opacity(
                      opacity: recipe.toolbarVisible ? 1 : 0,
                      child: Focus(
                        focusNode: toolbarGroup,
                        child: KeyedSubtree(
                          key: toolbarKey,
                          child: widget.toolbar!,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget portalBody(
    BuildContext context,
    RaftMessageRowRecipe recipe,
    Widget child,
  ) {
    // The wrapper depends only on the pointer model, never on TickerMode: a
    // covered route (a full-screen preview page on a narrow desktop window)
    // disables tickers, and toggling the wrapper would remount every row's
    // state, including the attachment owning that very preview route.
    if (widget.coarsePointer || widget.toolbar == null) {
      portalMounted = false;
      return child;
    }
    // A retained route/density change remounts a detached portal. Its unattached
    // controller can publish the current attention before the first layout.
    if (!portalMounted && toolbarActive && !portal.isShowing) portal.show();
    portalMounted = true;
    // Keep the wrapper stable when attention changes: inserting/removing it
    // would remount rich message state. Hidden portals mount no overlay child.
    // A distinct semantics boundary preserves this portal's traversal anchor
    // alongside tooltips when a lazy row is retained or recycled.
    return Semantics(
      container: true,
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: portal,
        overlayChildBuilder: (context, info) => toolbarActive
            ? overlay(context, info, recipe)
            : const SizedBox.shrink(),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            // CSS opacity hides paint, not keyboard traversal. An idle row keeps
            // only a focus stop where its actions sit in traversal order; the
            // strip itself is built in the portal once hover or focus reveals
            // it, so mounting a row never builds hidden controls.
            ExcludeSemantics(
              child: Offstage(
                child: Focus(
                  focusNode: toolbarProxy,
                  skipTraversal: toolbarActive,
                  child: const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // CSS places line-height leading evenly above and below the glyphs.
  @override
  Widget build(BuildContext context) => DefaultTextHeightBehavior(
    textHeightBehavior: raftCssTextHeightBehavior,
    child: Builder(builder: buildContent),
  );

  Widget buildContent(BuildContext context) {
    final recipe = RaftMessageRowRecipe(
      RaftTokens.of(context),
      viewportWidth: raftBreakpointWidth(context),
      rowContext: widget.rowContext,
      continuation: widget.continuation,
      nextContinuation: widget.nextContinuation,
      hovered: !widget.coarsePointer && (hovered || toolbarHovered),
      focused: focused,
      popupOpen: widget.popupOpen,
      highlighted: widget.highlighted,
    );
    // One widget shape whether or not the author is linkable: a mention
    // affordance that arrives after first paint never reflows the header.
    final author = RaftControl(
      key: const ValueKey('message-author'),
      onPressed: widget.onAuthor,
      inertWhenDisabled: true,
      kind: RaftControlKind.textLink,
      shadow: false,
      visualHeight: recipe.tokens.brutal ? 20 : 14,
      minimumTargetSize: 0,
      padding: EdgeInsets.zero,
      child: Text(
        widget.author,
        // An ellipsis implies a single line; wrapped text must not set one.
        maxLines: RaftScaled.grows(context) ? null : 1,
        overflow: RaftScaled.grows(context)
            ? TextOverflow.clip
            : TextOverflow.ellipsis,
        style: recipe.author,
      ),
    );
    // Compact rows announce author, metadata and time in their own label.
    final compact = widget.semanticsLabel != null;
    final gutterClock = widget.continuationTimestamp ?? widget.timestamp;
    final fullTimestamp = widget.timestampTooltip ?? widget.timestamp;
    final wrapHeader = RaftScaled.grows(context);
    final header = ClipRect(
      clipper: const _HeaderInlineClip(),
      // Wrapped lines are never cut off; the clip only trims the 1.0x line.
      clipBehavior: wrapHeader ? Clip.none : Clip.hardEdge,
      child: _MessageHeader(
        wrap: wrapHeader,
        lineHeight: recipe.headerLine,
        reserve: recipe.headerReserve,
        gap: recipe.headerGap,
        baseline: !recipe.tokens.brutal,
        subtitleIndex: widget.subtitle != null && widget.subtitle!.isNotEmpty
            ? (widget.metadata == null ? 1 : 2)
            : null,
        children: [
          author,
          if (widget.metadata != null)
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: recipe.headerLine),
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                alignment: Alignment.centerLeft,
                child: widget.metadata!,
              ),
            ),
          if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
            // The description repeats its own text: the tooltip opens only
            // while the single line is cut off.
            RaftTooltip(
              message: widget.subtitle!,
              onlyWhenTruncated: true,
              excludeFromSemantics: true,
              child: Text(
                widget.subtitle!,
                maxLines: wrapHeader ? null : 1,
                overflow: wrapHeader
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
                style: recipe.time,
              ),
            ),
          Text(
            widget.timestamp,
            maxLines: 1,
            softWrap: false,
            style: recipe.time,
          ),
        ],
      ),
    );
    final row = Listener(
      // Right-click reaches the row even over selectable body text (whose
      // SelectionArea wins the secondary-tap gesture arena), like Web's
      // `contextmenu` handler on the MessageItem root.
      onPointerDown: (event) {
        secondaryDown =
            widget.onActionsAt != null &&
            event.kind == PointerDeviceKind.mouse &&
            (event.buttons & kSecondaryMouseButton) != 0;
      },
      onPointerUp: (event) {
        if (!secondaryDown) return;
        secondaryDown = false;
        widget.onActionsAt?.call(event.position);
      },
      onPointerCancel: (_) => secondaryDown = false,
      child: Focus(
        canRequestFocus: false,
        includeSemantics: !compact,
        onFocusChange: (value) {
          if (focused != value) {
            attentionChanged(() {
              focused = value;
              if (value) scrollSuppressed = false;
            });
          }
        },
        child: RaftHoverRegion(
          onEnter: (_) {
            if (!widget.coarsePointer &&
                !hovered &&
                RaftPointerIntent.movedSinceScroll) {
              attentionChanged(() {
                hovered = true;
                scrollSuppressed = false;
              });
            }
          },
          onHover: (event) {
            if (!widget.coarsePointer &&
                !hovered &&
                event.delta != Offset.zero) {
              attentionChanged(() {
                hovered = true;
                scrollSuppressed = false;
              });
            }
          },
          onExit: (_) {
            if (hovered) attentionChanged(() => hovered = false);
          },
          child: GestureDetector(
            excludeFromSemantics: compact,
            onTap: widget.onTap,
            onLongPressStart: widget.onActionsAt != null
                ? (d) => widget.onActionsAt!(d.globalPosition)
                : widget.onActions == null
                ? null
                : (_) => widget.onActions!(),
            onSecondaryTapUp: widget.onActionsAt != null
                ? null
                : widget.onActions == null
                ? null
                : (_) => widget.onActions!(),
            behavior: HitTestBehavior.translucent,
            child: Padding(
              padding: recipe.margin,
              child: Container(
                constraints: BoxConstraints(minHeight: recipe.minimumHeight),
                decoration: recipe.decoration,
                // Container inserts/removes a wrapper for a nullable foreground
                // decoration. Keep that wrapper mounted when focus paint expires
                // so rich-content tabs, selection and copy state survive.
                foregroundDecoration:
                    recipe.highlightRing ?? const BoxDecoration(),
                child: portalBody(
                  context,
                  recipe,
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                        padding: recipe.padding,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.selectionLeading != null) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: widget.selectionLeading,
                              ),
                              SizedBox(width: recipe.gap),
                            ],
                            SizedBox(
                              width: recipe.gutterWidth,
                              // The hover time (10px, 4px down) grows with
                              // the text size and stays inside its box.
                              height: widget.continuation
                                  ? math.max(
                                      14,
                                      4 +
                                          MediaQuery.textScalerOf(context)
                                              .scale(10),
                                    )
                                  : recipe.avatarExtent + recipe.avatarTop,
                              child: widget.continuation
                                  ? Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Positioned(
                                          left: 0,
                                          right: 4,
                                          top: 0,
                                          bottom: 0,
                                          child: ExcludeSemantics(
                                            excluding: compact,
                                            child: RaftTooltip(
                                              message: fullTimestamp,
                                              enabled:
                                                  fullTimestamp != gutterClock,
                                              excludeFromSemantics: compact,
                                              // Keep the tooltip anchor as tall
                                              // as the gutter even when the
                                              // clock scales down to its width.
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 4,
                                                ),
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.topRight,
                                                  child: Text(
                                                    gutterClock,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style:
                                                        recipe.continuationTime,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Padding(
                                      padding: EdgeInsets.only(
                                        top: recipe.avatarTop,
                                      ),
                                      child: OverflowBox(
                                        alignment: Alignment.topLeft,
                                        minWidth: recipe.avatarExtent,
                                        maxWidth: recipe.avatarExtent,
                                        minHeight: recipe.avatarExtent,
                                        maxHeight: recipe.avatarExtent,
                                        child: SizedBox.square(
                                          dimension: recipe.avatarExtent,
                                          child: ExcludeSemantics(
                                            excluding: compact,
                                            child: widget.avatar,
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                            SizedBox(width: recipe.gap),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!widget.continuation)
                                    ExcludeSemantics(
                                      excluding: compact,
                                      child: header,
                                    ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: recipe.bodyGap,
                                    ),
                                    child: RaftMessageBodyMargin(
                                      gap: recipe.bodyGap,
                                      child: DefaultTextStyle.merge(
                                        style: recipe.body,
                                        // Only the body reports its collapse.
                                        child: compact
                                            ? RaftMessageSemanticsScope(
                                                visibleFraction:
                                                    visibleFraction,
                                                child: widget.content,
                                              )
                                            : widget.content,
                                      ),
                                    ),
                                  ),
                                  if (widget.attachments != null)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        // `mt-1` collapses with the body's
                                        // bottom margin (max, not sum).
                                        top:
                                            (recipe.attachmentGap -
                                                    recipe.bodyGap)
                                                .clamp(0.0, double.infinity),
                                      ),
                                      child: widget.attachments!,
                                    ),
                                  // `div.mt-0` keeps the content column's line
                                  // box (20px, Elegant leading-5.25 = 21px); the
                                  // 11px inline-flex status sits on its baseline.
                                  if (widget.translation != null)
                                    Container(
                                      // The status line is a minimum height
                                      // above the default text size.
                                      height: wrapHeader
                                          ? null
                                          : recipe.translationLine,
                                      constraints: wrapHeader
                                          ? BoxConstraints(
                                              minHeight: recipe.translationLine,
                                            )
                                          : null,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: EdgeInsets.only(
                                            bottom: recipe.translationLift,
                                          ),
                                          child: widget.translation,
                                        ),
                                      ),
                                    ),
                                  if (widget.footer != null)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        // Source block margins collapse: body
                                        // bottom6 + footer top6 paint one6 gap.
                                        top:
                                            widget.attachments == null &&
                                                widget.translation == null
                                            ? (recipe.footerGap -
                                                      recipe.bodyGap)
                                                  .clamp(0.0, double.infinity)
                                            : recipe.footerGap,
                                      ),
                                      child: widget.footer!,
                                    ),
                                  if (widget.inlineReplies != null)
                                    widget.inlineReplies!,
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!compact) return row;
    return ValueListenableBuilder<double?>(
      valueListenable: visibleFraction,
      builder: (context, fraction, child) {
        final text = raftMessageSemanticsExcerpt(
          widget.semanticsText,
          fraction,
        );
        return RaftMessageRowSemantics(
          label: text.isEmpty
              ? widget.semanticsLabel!
              : '${widget.semanticsLabel}\n$text',
          actions: [
            for (final action in widget.semanticsActions) action.label,
            if (widget.onAuthor != null)
              raftFormat(context, 'Mention {name}', {'name': widget.author}),
          ],
          onAction: semanticsAction,
          onLongPress: widget.onActionsAt != null || widget.onActions != null
              ? semanticsLongPress
              : null,
          child: child,
        );
      },
      child: row,
    );
  }

  void semanticsAction(int index) {
    if (!mounted) return;
    final actions = widget.semanticsActions;
    if (index < actions.length) {
      actions[index].onInvoke(context);
    } else {
      widget.onAuthor?.call();
    }
  }

  /// Assistive long press opens the message menu at the row, like the
  /// pointer long press does at the touch point.
  void semanticsLongPress() {
    if (!mounted) return;
    if (widget.onActionsAt case final open?) {
      final box = context.findRenderObject();
      open(
        box is RenderBox && box.hasSize
            ? box.localToGlobal(box.size.center(Offset.zero))
            : Offset.zero,
      );
    } else {
      widget.onActions?.call();
    }
  }
}

/// Source action-strip frame; its children are permission-controlled actions.
class RaftMessageToolbar extends StatelessWidget {
  const RaftMessageToolbar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final recipe = RaftMessageRowRecipe(
      RaftTokens.of(context),
      viewportWidth: raftBreakpointWidth(context),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    return Container(
      decoration: recipe.toolbarDecoration,
      padding: recipe.toolbarPadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: recipe.toolbarGap),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Fine-pointer toolbar action. Icon geometry remains a caller-supplied slot,
/// so missing source ThreadIcon/SmilePlus paths cannot silently become Material glyphs.
class RaftMessageToolbarAction extends StatelessWidget {
  const RaftMessageToolbarAction({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.active = false,
    this.popupOpen = false,
  });
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool active, popupOpen;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final extent = t.brutal ? 24.0 : 28.0;
    return RaftControl(
      onPressed: onPressed,
      tooltip: label,
      semanticLabel: label,
      visualHeight: extent,
      visualWidth: extent,
      minimumTargetSize: extent,
      padding: EdgeInsets.zero,
      shadow: true,
      recipe: _MessageActionRecipe(t, active: active, popupOpen: popupOpen),
      child: SizedBox.square(dimension: 13, child: icon),
    );
  }
}

class _MessageActionRecipe extends RaftControlRecipe {
  const _MessageActionRecipe(
    super.tokens, {
    required this.active,
    required this.popupOpen,
  }) : super(variant: RaftControlVariant.ghost);
  final bool active, popupOpen;
  @override
  bool get transformsOnInteraction => false;
  @override
  BorderRadius get radius => BorderRadius.circular(tokens.brutal ? 0 : 6);
  @override
  Color get foreground => foregroundFor();
  @override
  Color foregroundFor({bool hovered = false}) => active
      ? tokens.colors[tokens.brutal ? 'color-brutal-orange' : 'accent-strong']!
      : tokens.brutal
      ? RaftPrimitiveColors.black.withValues(
          alpha: hovered || popupOpen ? 1 : .5,
        )
      : hovered || popupOpen
      ? tokens.strong
      : tokens.colors['foreground-icon']!;
  @override
  Color backgroundFor({bool hovered = false}) => hovered || popupOpen
      ? tokens.brutal
            ? tokens.primaryFill.withValues(alpha: .3)
            : tokens.colors['fill-muted']!
      : Colors.transparent;
  @override
  Color get focusRing =>
      tokens.brutal ? Colors.transparent : tokens.colors['primary-500']!;
  @override
  BorderSide side({bool hovered = false}) =>
      const BorderSide(color: Colors.transparent, width: 0);
  @override
  List<BoxShadow> shadows({
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
  }) => focused && !tokens.brutal
      ? [BoxShadow(color: focusRing, spreadRadius: .5)]
      : const [];
}

class _MessageToolbarClip extends CustomClipper<Rect> {
  const _MessageToolbarClip(this.viewport);
  final Rect viewport;
  @override
  Rect getClip(Size size) => viewport;
  @override
  bool shouldReclip(covariant _MessageToolbarClip oldClipper) =>
      oldClipper.viewport != viewport;
}

/// Clips the header at its left and right edges only. The header box is one
/// CSS line tall (Elegant `leading-none` = 14px), shorter than the glyph box of
/// the font, so a vertical clip at the box edge cuts descenders (`g`, `y`) and,
/// for fallback faces such as PingFang SC / Noto CJK, the tops of ideographs.
/// Only the horizontal reserve (`pr-24`) needs to hide overflowing items.
class _HeaderInlineClip extends CustomClipper<Rect> {
  const _HeaderInlineClip();

  /// More than any font's ascent/descent overflow of a 14px line.
  static const bleed = 64.0;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, -bleed, size.width, size.height + bleed);

  @override
  bool shouldReclip(covariant _HeaderInlineClip oldClipper) => false;
}

// Source flex header keeps sender/model/clock shrink-0. Only description can
// shrink; fixed children may paint into pr-24, clipped at the header boundary.
// A normal constrained Row reports an overflow instead of that CSS behavior.
class _MessageHeader extends MultiChildRenderObjectWidget {
  const _MessageHeader({
    required super.children,
    required this.lineHeight,
    required this.reserve,
    required this.gap,
    required this.baseline,
    required this.subtitleIndex,
    required this.wrap,
  });
  final double lineHeight, reserve, gap;
  final bool baseline;
  final int? subtitleIndex;

  /// Larger text: name, description and time flow onto further lines when they
  /// do not fit one, instead of being clipped.
  final bool wrap;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMessageHeader(
    lineHeight,
    reserve,
    gap,
    baseline,
    subtitleIndex,
    wrap,
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMessageHeader renderObject,
  ) {
    renderObject.update(
      lineHeight,
      reserve,
      gap,
      baseline,
      subtitleIndex,
      wrap,
    );
  }
}

class _HeaderParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderMessageHeader extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderParentData> {
  _RenderMessageHeader(
    this.lineHeight,
    this.reserve,
    this.gap,
    this.baseline,
    this.subtitleIndex,
    this.wrap,
  );
  double lineHeight, reserve, gap;
  bool baseline;
  int? subtitleIndex;
  bool wrap;
  void update(
    double height,
    double inset,
    double spacing,
    bool alignBaseline,
    int? subtitle,
    bool wrapLines,
  ) {
    if (lineHeight == height &&
        reserve == inset &&
        gap == spacing &&
        baseline == alignBaseline &&
        subtitleIndex == subtitle &&
        wrap == wrapLines) {
      return;
    }
    lineHeight = height;
    reserve = inset;
    gap = spacing;
    baseline = alignBaseline;
    subtitleIndex = subtitle;
    wrap = wrapLines;
    markNeedsLayout();
  }

  /// Start index of each wrapped line for children of [widths] in [maxWidth].
  List<int> _lineStarts(List<double> widths, double maxWidth) {
    final starts = <int>[0];
    var x = 0.0;
    for (var i = 0; i < widths.length; i++) {
      if (i > starts.last && x + widths[i] > maxWidth + 1e-6) {
        starts.add(i);
        x = 0;
      }
      x += widths[i] + gap;
    }
    return starts;
  }

  Size _wrapDryLayout(BoxConstraints constraints) {
    final children = getChildrenAsList();
    final loose = BoxConstraints(
      maxWidth: constraints.hasBoundedWidth
          ? constraints.maxWidth
          : double.infinity,
    );
    final sizes = [for (final child in children) child.getDryLayout(loose)];
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : sizes.fold(0.0, (v, s) => v + s.width) +
              gap * (sizes.length - 1).clamp(0, sizes.length);
    final starts = _lineStarts([for (final s in sizes) s.width], width);
    var height = 0.0;
    for (var l = 0; l < starts.length; l++) {
      final end = l + 1 < starts.length ? starts[l + 1] : sizes.length;
      height += sizes
          .sublist(starts[l], end)
          .fold(0.0, (v, s) => v > s.height ? v : s.height);
    }
    return constraints.constrain(Size(width, height));
  }

  void _wrapLayout() {
    final children = getChildrenAsList();
    final loose = BoxConstraints(
      maxWidth: constraints.hasBoundedWidth
          ? constraints.maxWidth
          : double.infinity,
    );
    for (final child in children) {
      child.layout(loose, parentUsesSize: true);
    }
    final natural =
        children.fold(0.0, (v, c) => v + c.size.width) +
        gap * (children.length - 1).clamp(0, children.length);
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : natural;
    final starts = _lineStarts([for (final c in children) c.size.width], width);
    var y = 0.0;
    for (var l = 0; l < starts.length; l++) {
      final end = l + 1 < starts.length ? starts[l + 1] : children.length;
      final line = children.sublist(starts[l], end);
      final height = line.fold(
        0.0,
        (v, c) => v > c.size.height ? v : c.size.height,
      );
      final baselines = [
        for (final child in line)
          child.getDistanceToBaseline(TextBaseline.alphabetic) ??
              child.size.height,
      ];
      final topBaseline = baselines.fold(0.0, (a, b) => a > b ? a : b);
      var x = 0.0;
      for (var i = 0; i < line.length; i++) {
        (line[i].parentData! as _HeaderParentData).offset = Offset(
          x,
          y +
              (baseline
                  ? topBaseline - baselines[i]
                  : (height - line[i].size.height) / 2),
        );
        x += line[i].size.width + gap;
      }
      y += height;
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderParentData)
      child.parentData = _HeaderParentData();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (wrap) return _wrapDryLayout(constraints);
    final sizes = [
      for (final child in getChildrenAsList())
        child.getDryLayout(const BoxConstraints()),
    ];
    final height = sizes.fold(
      0.0,
      (value, size) => value > size.height ? value : size.height,
    );
    return constraints.constrain(
      Size(constraints.hasBoundedWidth ? constraints.maxWidth : 0, height),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) => wrap
      ? _wrapDryLayout(BoxConstraints(maxWidth: width)).height
      : lineHeight;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  void performLayout() {
    if (wrap) {
      _wrapLayout();
      return;
    }
    final children = getChildrenAsList();
    var fixed = gap * (children.length - 1).clamp(0, children.length);
    // CSS flex items can enlarge the line: the 10px departure badge inherits
    // 20/14 leading and adds 6px border/padding, yielding 20.2857px in Brutal.
    const natural = BoxConstraints();
    for (var i = 0; i < children.length; i++) {
      if (i == subtitleIndex) continue;
      children[i].layout(natural, parentUsesSize: true);
      fixed += children[i].size.width;
    }
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : fixed + reserve;
    if (subtitleIndex != null) {
      final remaining = (width - reserve - fixed).clamp(0.0, double.infinity);
      children[subtitleIndex!].layout(
        BoxConstraints(maxWidth: remaining),
        parentUsesSize: true,
      );
    }
    final height = children.fold(
      0.0,
      (value, child) => value > child.size.height ? value : child.size.height,
    );
    size = constraints.constrain(Size(width, height));
    final baselines = [
      for (final child in children)
        child.getDistanceToBaseline(TextBaseline.alphabetic) ??
            child.size.height,
    ];
    final topBaseline = baselines.fold(0.0, (a, b) => a > b ? a : b);
    var x = 0.0;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      (child.parentData! as _HeaderParentData).offset = Offset(
        x,
        baseline
            ? topBaseline - baselines[i]
            : (size.height - child.size.height) / 2,
      );
      x += child.size.width + gap;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
