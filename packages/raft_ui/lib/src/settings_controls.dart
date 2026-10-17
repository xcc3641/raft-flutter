import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_primitives.dart' hide RaftPanelHeaderRecipe;
import 'error_presentation.dart';
import 'form_presentation.dart';
import 'icons.dart';
import 'localization.dart';
import 'overlays/dialog.dart' show showRaftDialog;
import 'panel_layout.dart' show RaftCssText;
import 'recipe_min_height.dart';
import 'recipe_surface.dart';
import 'recipes/recipe_runtime.dart';
import 'recipes/recipes.g.dart';
import 'recipes/token_binding.dart';
import 'settings_layout.dart';
import 'sized_image.dart';
import 'theme.dart' hide RaftFieldRecipe;
import 'text_scaling.dart' show RaftScaled;
import 'tooltip.dart' show RaftTooltip;

/// Recipe-driven controls the Settings pages compose. Every geometry, colour
/// and type value comes from the generated raft-ui recipes
/// (`buttonVariants`, `input`, `inputGroup`, `field`, `dialog`); callsite
/// class overrides from the Web JSX are passed explicitly and cited.

RaftRecipeStates _states(
  RaftTokens t, {
  bool hovered = false,
  bool pressed = false,
  bool disabled = false,
  bool focused = false,
}) => RaftRecipeStates({
  if (hovered && !disabled) RaftRecipeStates.hover,
  if (pressed && !disabled) RaftRecipeStates.active,
  if (disabled) RaftRecipeStates.disabled,
  if (focused) RaftRecipeStates.focus,
  if (t.dark) RaftRecipeStates.dark,
});

TextStyle _slotText(RaftTokens t, RaftSlotStyle s, {TextStyle? base}) {
  final tokens = RaftRecipeTokens(t);
  final style = s.textStyle(tokens);
  return (base ??
          RaftTypography.heading(
            t,
            size: 14,
            line: 20,
            weight: FontWeight.w400,
          ))
      .merge(style)
      .copyWith(fontVariations: const [], fontFamilyFallback: t.fontFallback);
}

/// Tailwind preflight `::placeholder { color: color-mix(in oklab,
/// currentcolor 50%, transparent) }`.
Color _placeholder(Color current) => current.withValues(alpha: current.a * .5);

/// A borderless, padding-free field decoration: the recipe container owns
/// border, fill and padding (the app theme's input decoration must not apply).
InputDecoration _bare({String? hint, TextStyle? hintStyle}) => InputDecoration(
  isCollapsed: true,
  isDense: true,
  filled: false,
  contentPadding: EdgeInsets.zero,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  hintText: hint,
  hintStyle: hintStyle,
);

/// raft-ui `Button` rendered from `RaftButtonRecipe`.
class RaftSettingsRecipeButton extends StatefulWidget {
  const RaftSettingsRecipeButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = RaftButtonRecipeVariant.outline,
    this.size = RaftButtonRecipeSize.md,
    this.glyph,
    this.glyphSize,
    this.expand = false,
    this.disabledOpacity,
    this.restColor,
    this.trailingGlyph,
    this.semanticLabel,
  });

  /// Accessible name for icon-only buttons.
  final String? semanticLabel;

  /// Icon after the label (`Finish setup <ChevronRight size={14} />`).
  final RaftGlyph? trailingGlyph;
  final String label;
  final VoidCallback? onPressed;
  final RaftButtonRecipeVariant variant;
  final RaftButtonRecipeSize size;
  final RaftGlyph? glyph;

  /// Callsite icon size (`<Trash2 size={14} />`); defaults to the recipe's
  /// `& svg:not([class*='size-'])` size.
  final double? glyphSize;

  /// Block layout (a flex-col parent stretches the button).
  final bool expand;

  /// Callsite `disabled:opacity-*` override (ConfirmDialog uses 80 / 30).
  final double? disabledOpacity;

  /// Callsite `text-*` colour while not hovered (DialogClose's
  /// `text-foreground-placeholder hover:text-foreground-strong`).
  final Color? restColor;
  @override
  State<RaftSettingsRecipeButton> createState() =>
      _RaftSettingsRecipeButtonState();
}

class _RaftSettingsRecipeButtonState extends State<RaftSettingsRecipeButton> {
  @override
  Widget build(BuildContext context) => RaftInteractive(
    onPressed: widget.onPressed,
    builder: (context, state) {
      final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
      final s = RaftButtonRecipe.resolve(
        theme: raftRecipeTheme(t),
        variant: widget.variant,
        size: widget.size,
        states: t.recipeStates(
          hovered: state.hovered,
          pressed: state.pressed,
          focusVisible: state.focusVisible,
          disabled: !state.enabled,
        ),
        tokens: tokens,
      ).root;
      final base = _slotText(t, s);
      final text = widget.restColor != null && !state.hovered
          ? base.copyWith(color: widget.restColor)
          : base;
      final svg = s.target("& svg:not([class*='size-'])");
      final opacity = !state.enabled
          ? (widget.disabledOpacity ?? s.opacity ?? 1)
          : (s.opacity ?? 1);
      final grows = RaftScaled.grows(context);
      final button = Opacity(
        opacity: opacity,
        child: RaftRecipeBox(
          style: raftGrowingHeight(context, s),
          tokens: tokens,
          applyText: false,
          applyOpacity: false,
          overflowCenter: true,
          child: Row(
            mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.glyph != null) ...[
                RaftIcon(
                  widget.glyph!,
                  size: widget.glyphSize ?? svg?.width ?? 16,
                  color: text.color,
                ),
                if (widget.label.isNotEmpty) SizedBox(width: s.columnGap ?? 6),
              ],
              if (widget.label.isNotEmpty)
                // Above the default text size the label wraps inside the
                // button instead of escaping it.
                if (grows)
                  Flexible(
                    child: Text(
                      raftText(context, widget.label),
                      textAlign: TextAlign.center,
                      style: text,
                    ),
                  )
                else
                  Text(
                    raftText(context, widget.label),
                    maxLines: 1,
                    softWrap: false,
                    style: text,
                  ),
              if (widget.trailingGlyph != null) ...[
                SizedBox(width: s.columnGap ?? 6),
                RaftIcon(
                  widget.trailingGlyph!,
                  size: widget.glyphSize ?? svg?.width ?? 16,
                  color: text.color,
                ),
              ],
            ],
          ),
        ),
      );
      final name = widget.semanticLabel;
      return name == null
          ? button
          : Semantics(
              button: true,
              enabled: state.enabled,
              label: name,
              excludeSemantics: true,
              child: button,
            );
    },
  );
}

/// FormField.tsx `labelStyle="plain" size="compact"`: raft-ui `Field`
/// (`flex flex-col gap-1`) with a FieldLabel `mb-1 block text-xs`.
class RaftSettingsField extends StatelessWidget {
  const RaftSettingsField({
    super.key,
    required this.label,
    required this.child,
  });
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final f = RaftFieldRecipe.resolve(
      theme: raftRecipeTheme(t),
      // `dark:text-foreground-hint` on the elegant label.
      states: t.recipeStates(),
      tokens: RaftRecipeTokens(t),
    );
    // tailwind-merge: the callsite `text-xs` replaces the recipe `text-sm`
    // and drops `leading-none`, so the label is 12px / 16px.
    final style = _slotText(t, f.label).copyWith(fontSize: 12, height: 16 / 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(raftText(context, label), style: style),
        SizedBox(height: (f.root.rowGap ?? 4) + 4),
        child,
      ],
    );
  }
}

/// raft-ui `Input` (`input` recipe) with a callsite text size.
class RaftRecipeInput extends StatefulWidget {
  const RaftRecipeInput({
    super.key,
    this.fieldKey,
    this.controller,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.mono = false,
    this.padding,
    this.autofocus = false,
    this.focusNode,
    this.enabled = true,
    this.numeric = false,
    this.upperCase = false,
    this.height,
    this.keyboardType,
    this.inputFormatters,
    this.maxLength,
    this.recipeText = false,
    this.obscure = false,
    this.readOnly = false,
  });

  /// `readOnly`.
  final bool readOnly;

  /// `type="password"`.
  final bool obscure;

  /// No callsite `text-sm`: the recipe's own size and leading (Elegant 14/20,
  /// Brutal 16/24).
  final bool recipeText;

  /// Callsite fixed box height (`box-border h-10`); content centres.
  final double? height;

  /// Caller-owned focus (e.g. commit on blur); else the field owns one.
  final FocusNode? focusNode;

  /// `disabled` (the recipe's disabled state).
  final bool enabled;

  /// `inputMode="numeric" pattern="[0-9]*"`: digits only.
  final bool numeric;

  /// Callsite `uppercase` (the value renders upper-cased; the typed text is
  /// kept, like CSS `text-transform`).
  final bool upperCase;

  /// `type="number"` and friends.
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// `maxLength`.
  final int? maxLength;

  /// Key for the inner [TextField] (tests and focus lookups).
  final Key? fieldKey;
  final TextEditingController? controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged, onSubmitted;
  final bool mono;

  /// JSX `autoFocus`.
  final bool autofocus;

  /// Callsite padding override (`theme-brutal:p-2` on the account name).
  final EdgeInsets? padding;
  @override
  State<RaftRecipeInput> createState() => _RaftRecipeInputState();
}

class _RaftRecipeInputState extends State<RaftRecipeInput> {
  late final FocusNode own = FocusNode();
  FocusNode get focus => widget.focusNode ?? own;
  void _focusChanged() => setState(() {});
  @override
  void initState() {
    super.initState();
    focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(RaftRecipeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? own).removeListener(_focusChanged);
      focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    focus.removeListener(_focusChanged);
    own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
    final s = RaftInputRecipe.resolve(
      theme: raftRecipeTheme(t),
      states: _states(t, focused: focus.hasFocus, disabled: !widget.enabled),
      tokens: tokens,
    ).root;
    // Callsite `text-sm`.
    var text = widget.recipeText
        ? _slotText(t, s)
        : _slotText(t, s).copyWith(fontSize: 14, height: 20 / 14);
    if (widget.mono) {
      text = text.copyWith(fontFamily: t.monoFont);
    }
    // A fixed box height is a minimum once the text is larger than the
    // default: the field grows with the text it holds.
    final grows = widget.height != null && RaftScaled.grows(context);
    final field = Container(
      height: grows ? null : widget.height,
      constraints: grows ? BoxConstraints(minHeight: widget.height!) : null,
      alignment: widget.height == null ? null : Alignment.centerLeft,
      decoration: s.decoration(tokens),
      padding: widget.padding ?? s.padding,
      child: TextField(
        autofillHints: null,
        key: widget.fieldKey,
        controller: widget.controller,
        focusNode: focus,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        readOnly: widget.readOnly,
        obscureText: widget.obscure,
        enableSuggestions: !widget.obscure,
        autocorrect: !widget.obscure,
        keyboardType:
            widget.keyboardType ??
            (widget.numeric ? TextInputType.number : null),
        inputFormatters: [
          if (widget.numeric) FilteringTextInputFormatter.digitsOnly,
          ...?widget.inputFormatters,
          if (widget.maxLength != null)
            LengthLimitingTextInputFormatter(widget.maxLength),
        ],
        textCapitalization: widget.upperCase
            ? TextCapitalization.characters
            : TextCapitalization.none,
        style: text,
        cursorColor: text.color ?? t.strong,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        decoration: _bare(
          hint: widget.placeholder,
          hintStyle: text.copyWith(color: _placeholder(text.color ?? t.strong)),
        ),
      ),
    );
    // `disabled:opacity-*` lives on the recipe root.
    return widget.enabled
        ? field
        : Opacity(opacity: s.opacity ?? .6, child: field);
  }
}

/// raft-ui `Textarea` (`textarea` recipe) with the callsite `text-sm
/// leading-relaxed` and a `min-h-*` box (MachineDetailPanel description).
class RaftRecipeTextarea extends StatefulWidget {
  const RaftRecipeTextarea({
    super.key,
    this.fieldKey,
    this.controller,
    this.placeholder,
    this.onChanged,
    this.minHeight = 64,
    this.maxLength,
    this.autofocus = false,
    this.lineHeight = 1.625,
    this.recipeText = false,
  });

  /// No callsite text size / leading: the recipe's own (Elegant 14/20, Brutal
  /// 16/24).
  final bool recipeText;

  /// Callsite leading (`leading-relaxed` 1.625 by default; plain `text-sm` 20/14).
  final double lineHeight;
  final Key? fieldKey;
  final TextEditingController? controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final double minHeight;
  final int? maxLength;
  final bool autofocus;
  @override
  State<RaftRecipeTextarea> createState() => _RaftRecipeTextareaState();
}

class _RaftRecipeTextareaState extends State<RaftRecipeTextarea> {
  final focus = FocusNode();
  @override
  void initState() {
    super.initState();
    focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
    final s = RaftTextareaRecipe.resolve(
      theme: raftRecipeTheme(t),
      states: _states(t, focused: focus.hasFocus),
      tokens: tokens,
    ).root;
    // Callsite `text-sm leading-relaxed`.
    final text = widget.recipeText
        ? _slotText(t, s)
        : _slotText(t, s).copyWith(fontSize: 14, height: widget.lineHeight);
    return Container(
      constraints: BoxConstraints(minHeight: widget.minHeight),
      decoration: s.decoration(tokens),
      padding: s.padding,
      child: TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        focusNode: focus,
        autofocus: widget.autofocus,
        style: text,
        minLines: 1,
        maxLines: null,
        maxLength: widget.maxLength,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        cursorColor: text.color ?? t.strong,
        onChanged: widget.onChanged,
        decoration: _bare(
          hint: widget.placeholder,
          hintStyle: text.copyWith(color: _placeholder(text.color ?? t.strong)),
        ),
      ),
    );
  }
}

/// SlugInput.tsx / PrefixedInput: raft-ui `InputGroup` with an
/// `InputGroupAddon.Text variant="container"` prefix.
class RaftSettingsPrefixedInput extends StatefulWidget {
  const RaftSettingsPrefixedInput({
    super.key,
    required this.prefix,
    this.controller,
    this.value,
    this.placeholder,
    this.readOnly = false,
    this.mono = false,
    this.onChanged,
    this.rootColor,
    this.rootBorderColor,
    this.flat = false,
    this.textColor,
  });
  final String prefix;
  final TextEditingController? controller;

  /// Read-only value (ignored when [controller] is given).
  final String? value;
  final String? placeholder;
  final bool readOnly, mono;
  final ValueChanged<String>? onChanged;

  /// Callsite root overrides (`bg-*`, `border-*`, `shadow-none`) and the
  /// input `text-*` colour.
  final Color? rootColor, rootBorderColor, textColor;
  final bool flat;
  @override
  State<RaftSettingsPrefixedInput> createState() =>
      _RaftSettingsPrefixedInputState();
}

class _RaftSettingsPrefixedInputState extends State<RaftSettingsPrefixedInput> {
  final focus = FocusNode();
  late final TextEditingController own = TextEditingController(
    text: widget.value ?? '',
  );
  TextEditingController get controller => widget.controller ?? own;
  @override
  void initState() {
    super.initState();
    focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant RaftSettingsPrefixedInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == null && widget.value != oldWidget.value) {
      own.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    focus.dispose();
    own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
    final g = RaftInputGroupRecipe.resolve(
      theme: raftRecipeTheme(t),
      variant: RaftInputGroupRecipeVariant.container,
      states: RaftRecipeStates({
        if (focus.hasFocus) 'has:data-slot=input-group-control+focus',
        if (t.dark) RaftRecipeStates.dark,
      }),
      tokens: tokens,
    );
    final root = g.root.decoration(tokens);
    final border = root.border as Border?;
    final decoration = root.copyWith(
      color: widget.rootColor ?? root.color,
      border: widget.rootBorderColor == null || border == null
          ? border
          : Border.all(color: widget.rootBorderColor!, width: border.top.width),
      boxShadow: widget.flat ? const [] : root.boxShadow,
    );
    final addonDecoration = g.text.decoration(tokens);
    final addonBorder = addonDecoration.border as Border?;
    final prefixStyle = _slotText(t, g.text);
    var text = _slotText(
      t,
      g.control,
    ).copyWith(color: widget.textColor ?? t.strong);
    if (widget.mono) text = text.copyWith(fontFamily: t.monoFont);
    return Container(
      decoration: decoration,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: g.text.padding,
              alignment: Alignment.center,
              decoration: addonDecoration.copyWith(
                border: widget.rootBorderColor == null || addonBorder == null
                    ? addonBorder
                    : Border(
                        right: addonBorder.right.copyWith(
                          color: widget.rootBorderColor,
                        ),
                      ),
              ),
              child: Text(widget.prefix, style: prefixStyle),
            ),
            Expanded(
              child: Padding(
                padding: g.control.padding,
                child: TextField(
                  autofillHints: null,
                  controller: controller,
                  focusNode: focus,
                  readOnly: widget.readOnly,
                  enableInteractiveSelection: !widget.readOnly,
                  showCursor: !widget.readOnly,
                  onChanged: widget.onChanged,
                  style: text,
                  cursorColor: t.strong,
                  decoration: _bare(
                    hint: widget.placeholder,
                    hintStyle: text.copyWith(
                      color: _placeholder(text.color ?? t.strong),
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
}

/// ConfirmDialog.tsx on raft-ui `Dialog` (`dialog` recipe, `max-w-sm`).
class RaftConfirmDialog extends StatefulWidget {
  const RaftConfirmDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.confirmVariant = RaftButtonRecipeVariant.danger,
    this.confirmEnabled,
    this.confirmKey,
    this.maxWidth = 384,
    this.surfaceKey,
    this.showCancel = true,
    this.onConfirm,
    this.loadingLabel,
    this.confirmGlyph,
    this.actionSize = RaftButtonRecipeSize.sm,
  });

  /// ConfirmDialog `actionSize` (`xs` for confirmations in dense surfaces).
  final RaftButtonRecipeSize actionSize;

  /// ConfirmDialog `confirmIcon` (`<RotateCcw size={14} />`).
  final RaftGlyph? confirmGlyph;

  /// ConfirmDialog `onConfirm`: when set, Confirm runs it with the dialog
  /// open (both buttons disabled, Confirm reads [loadingLabel] beside a
  /// spinner) and closes with `true` once it completes. A failure keeps the
  /// dialog open and shows the error under the message.
  final Future<void> Function()? onConfirm;

  /// ConfirmDialog `loadingLabel` (default "Processing…").
  final String? loadingLabel;

  /// Key of the dialog surface itself (`dialog-content`).
  final Key? surfaceKey;

  /// ConfirmDialog `hideCancel` inverse.
  final bool showCancel;
  final String title;

  /// Plain copy rendered in `text-sm leading-relaxed text-foreground-muted`.
  final String? message;

  /// Rich message (the caller's own layout inside the same text style).
  final Widget? content;
  final String confirmLabel, cancelLabel;
  final RaftButtonRecipeVariant confirmVariant;

  /// `confirmDisabled` inverse; null keeps the confirm action enabled.
  final ValueListenable<bool>? confirmEnabled;
  final Key? confirmKey;
  final double maxWidth;

  /// [overModal]: the confirmation opens over another Modal (the channel
  /// members dialog), so its Brutal scrim composites over that one's.
  static Future<bool?> show(
    BuildContext context,
    RaftConfirmDialog dialog, {
    bool overModal = false,
  }) => showRaftDialog<bool>(
    context: context,
    barrierDismissible: false,
    overModal: overModal,
    builder: (_) => dialog,
  );

  /// `text-sm leading-relaxed text-foreground-muted` (font-normal body).
  static TextStyle messageStyle(RaftTokens t) =>
      RaftTypography.body(t, size: 14, line: 14 * 1.625, color: t.muted);

  @override
  State<RaftConfirmDialog> createState() => _RaftConfirmDialogState();
}

class _RaftConfirmDialogState extends State<RaftConfirmDialog> {
  bool loading = false;
  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared when the next confirm starts; the dialog state is dropped when it closes.
  String? error;

  Future<void> confirm() async {
    final run = widget.onConfirm;
    if (run == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await run();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          // Web ConfirmDialog: the server's error text, else the generic copy.
          error = raftErrorMessage(context, e);
        });
      }
    }
  }

  void cancel() {
    if (!loading) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final title = widget.title, message = widget.message;
    final content = widget.content, maxWidth = widget.maxWidth;
    final t = RaftTokens.of(context);
    Widget body = DefaultTextStyle.merge(
      style: RaftConfirmDialog.messageStyle(t),
      child: content ?? RaftCssText(raftText(context, message ?? '')),
    );
    if (error case final error?) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          // ConfirmDialog: `<Banner intent="warning" className="mt-4">`.
          const SizedBox(height: 16),
          RaftErrorBanner(error),
        ],
      );
    }
    // Web ConfirmDialog gates every close on `loading`: Escape, Back and the
    // X all wait for the running confirm.
    return PopScope(
      canPop: !loading,
      child: RaftDialogShell(
        surfaceKey: widget.surfaceKey,
        title: title,
        maxWidth: maxWidth,
        onClose: loading ? null : cancel,
        body: body,
        footer: [
          if (widget.showCancel)
            RaftSettingsRecipeButton(
              label: widget.cancelLabel,
              size: widget.actionSize,
              disabledOpacity: .3,
              onPressed: loading ? null : cancel,
            ),
          ValueListenableBuilder<bool>(
            valueListenable:
                widget.confirmEnabled ?? const AlwaysStoppedAnimation(true),
            builder: (context, enabled, _) => RaftSettingsRecipeButton(
              key: widget.confirmKey,
              label: loading
                  ? widget.loadingLabel ?? 'Processing…'
                  : widget.confirmLabel,
              glyph: loading ? null : widget.confirmGlyph,
              variant: widget.confirmVariant,
              size: widget.actionSize,
              disabledOpacity: .8,
              onPressed: enabled && !loading ? confirm : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// raft-ui `Dialog` chrome as ConfirmDialog.tsx composes it: the centred
/// `dialog` recipe surface (Brutal padded content with `gap-4`; Elegant
/// unpadded header `px-6 py-3`, body `px-6 py-5`, footer `px-6 py-3`), the
/// uppercase title with its close button, the scrolling [body] and the right
/// aligned [footer] actions. [onClose] null disables the close button.
///
/// In a presented form window on a phone ([showRaftForm], below 768) the shell
/// is the sheet: the title and close button pin to the top, [body] scrolls and
/// the [footer] actions pin to the bottom, above the keyboard.
class RaftDialogShell extends StatefulWidget {
  const RaftDialogShell({
    super.key,
    required this.title,
    required this.body,
    required this.footer,
    this.onClose,
    this.maxWidth = 384,
    this.surfaceKey,
    this.outlineClose = false,
  });
  final String title;
  final Widget body;
  final List<Widget> footer;
  final VoidCallback? onClose;
  final double maxWidth;
  final Key? surfaceKey;

  /// `<Button variant="outline" size="icon-md"><X className="size-5" />`
  /// (AgentProfileEditDialog) instead of the ConfirmDialog `DialogClose`.
  final bool outlineClose;

  @override
  State<RaftDialogShell> createState() => _RaftDialogShellState();
}

class _RaftDialogShellState extends State<RaftDialogShell> {
  final _body = GlobalKey(debugLabel: 'dialog shell body');
  final _footer = GlobalKey(debugLabel: 'dialog shell footer');

  @override
  Widget build(BuildContext context) {
    final title = widget.title,
        onClose = widget.onClose,
        maxWidth = widget.maxWidth,
        footer = widget.footer;
    final body = KeyedSubtree(key: _body, child: widget.body);
    final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
    final size = MediaQuery.sizeOf(context);
    if (RaftFormFrame.sheetOf(context)) {
      return RaftFormSheet(
        title: raftText(context, title),
        onClose: onClose,
        body: body,
        footer: KeyedSubtree(
          key: _footer,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: RaftSpace.x3,
            runSpacing: RaftSpace.x3,
            children: footer,
          ),
        ),
      );
    }
    final d = RaftDialogRecipe.resolve(
      theme: raftRecipeTheme(t),
      states: RaftRecipeStates(
        {if (t.dark) RaftRecipeStates.dark},
        size.width,
        size.height,
      ),
      tokens: tokens,
    );
    // Brutal: padded content with `gap-4`; Elegant: an unpadded popup whose
    // header (`px-6 py-3`), body (`px-6 py-5`) and footer (`px-6 py-3`) own
    // their padding and sit flush.
    final gap = d.content.rowGap ?? (t.brutal ? 16.0 : 0.0);
    final titleStyle = _slotText(t, d.title);
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: widget.surfaceKey,
          width: (size.width - 32).clamp(0, maxWidth).toDouble(),
          constraints: BoxConstraints(maxHeight: size.height - 32),
          padding: d.content.padding,
          decoration: d.content.decoration(tokens),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: d.header.padding,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        raftText(context, title).toUpperCase(),
                        style: titleStyle,
                      ),
                    ),
                    SizedBox(width: d.header.columnGap ?? 12),
                    RaftSettingsRecipeButton(
                      key: const Key('confirm-dialog-close'),
                      label: '',
                      glyph: RaftGlyph.x,
                      // DialogClose: brutal `outline` / `icon-md`, X `size-5`.
                      variant: t.brutal || widget.outlineClose
                          ? RaftButtonRecipeVariant.outline
                          : RaftButtonRecipeVariant.ghost,
                      size: t.brutal || widget.outlineClose
                          ? RaftButtonRecipeSize.iconMd
                          : RaftButtonRecipeSize.iconSm,
                      glyphSize: t.brutal || widget.outlineClose ? 20 : 16,
                      restColor: t.brutal || widget.outlineClose
                          ? null
                          : t.colors['foreground-placeholder'],
                      onPressed: raftGuardedClose(context, onClose),
                    ),
                  ],
                ),
              ),
              SizedBox(height: gap),
              Flexible(
                child: SingleChildScrollView(
                  padding: d.body.padding,
                  child: body,
                ),
              ),
              SizedBox(height: gap),
              Padding(
                padding: d.footer.padding,
                child: KeyedSubtree(
                  key: _footer,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: d.footer.columnGap ?? 12,
                    runSpacing: d.footer.rowGap ?? 12,
                    children: footer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// SettingsPanel.tsx DangerActionCard / AccountSignOutSection card: title,
/// `mt-0.5 text-xs` description and an action. [stacked] is the
/// DangerActionCard `flex-col gap-3` below `sm`, where the button stretches.
class RaftSettingsActionCard extends StatelessWidget {
  const RaftSettingsActionCard({
    super.key,
    required this.title,
    required this.description,
    required this.action,
    this.stacked = false,
  });
  final String title, description;
  final Widget action;
  final bool stacked;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          raftText(context, title),
          style: RaftTypography.body(
            t,
            size: 14,
            line: 20,
            weight: FontWeight.w700,
            color: t.brutal ? Colors.black : t.strong,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          raftText(context, description),
          style: RaftTypography.body(
            t,
            size: 12,
            line: 16,
            color: t.brutal ? Colors.black.withValues(alpha: .6) : t.muted,
          ),
        ),
      ],
    );
    final wide = MediaQuery.sizeOf(context).width >= 640;
    return RaftSettingsCard(
      child: stacked && !wide
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 12), action],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 16),
                action,
              ],
            ),
    );
  }
}

/// raft-ui `Badge` rendered from `RaftBadgeRecipe`.
class RaftSettingsRecipeBadge extends StatelessWidget {
  const RaftSettingsRecipeBadge({
    super.key,
    required this.label,
    this.variant,
    this.appearance,
    this.uppercase = false,
    this.glyph,
  });
  final String label;
  final RaftBadgeRecipeVariant? variant;
  final RaftBadgeRecipeAppearance? appearance;
  final bool uppercase;

  /// Leading icon (callsite size, e.g. `<Shield size={10} />`).
  final RaftGlyph? glyph;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = RaftRecipeTokens(t);
    final s = RaftBadgeRecipe.resolve(
      theme: raftRecipeTheme(t),
      variant: variant,
      appearance: appearance,
      uppercase: uppercase,
      states: RaftRecipeStates({
        if (glyph != null) 'has:svg',
        if (t.dark) RaftRecipeStates.dark,
      }),
      tokens: tokens,
    ).root;
    final text =
        _slotText(
          t,
          s,
          base: RaftTypography.body(t, size: 10, line: 10),
        ).copyWith(
          fontFamily: RaftInheritedFontScope.active(context)
              ? t.headingFont
              : null,
        );
    final value = raftText(context, label);
    return Container(
      height: s.height,
      padding: s.padding,
      decoration: s.decoration(tokens),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[
            RaftIcon(glyph!, size: 10, color: text.color),
            SizedBox(width: s.columnGap ?? 4),
          ],
          Text(
            // The recipe's `uppercase` axis only transforms Brutal.
            uppercase && s.textTransform == 'uppercase'
                ? value.toUpperCase()
                : value,
            maxLines: 1,
            softWrap: false,
            style: text,
          ),
        ],
      ),
    );
  }
}

/// ProfileSection read-only name: `w-full border border-line-muted
/// bg-layer-inset p-2 text-sm font-mono text-foreground-muted
/// theme-brutal:border-2 theme-brutal:border-black/30 theme-brutal:bg-gray-50
/// theme-brutal:text-black/60`.
class RaftSettingsReadonlyValue extends StatelessWidget {
  const RaftSettingsReadonlyValue({super.key, required this.value});
  final String value;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), text = RaftSettingsText(t);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: text.insetFill,
        border: Border.all(color: text.softEdge, width: t.brutal ? 2 : 1),
      ),
      child: Text(value, style: text.mono.copyWith(color: text.muted)),
    );
  }
}

/// AvatarSlot `profile-tile` for a server: `!size-16 !border-2`, `text-2xl
/// font-display font-bold theme-brutal:bg-soft-signal theme-brutal:text-black`.
///
/// With [onUpload] (ProfileSection `canEdit`) the tile is the Web upload
/// `<label>`: a tooltip, and a `bg-black/40` overlay with a white upload icon
/// while hovered or focused; [busy] dims it (`opacity-70`) and disables it.
class RaftServerProfileTile extends StatelessWidget {
  const RaftServerProfileTile({
    super.key,
    required this.initial,
    this.imageUrl,
    this.onUpload,
    this.busy = false,
    this.uploadLabel = 'Upload image',
    this.busyLabel = 'Uploading avatar',
  });
  final String initial;

  /// Resolved public avatar URL; the initial shows while it is absent or fails.
  final String? imageUrl;
  final VoidCallback? onUpload;
  final bool busy;
  final String uploadLabel, busyLabel;
  @override
  Widget build(BuildContext context) {
    if (onUpload == null) return _tile(context);
    // The control is labelled by its action, not by the initial it paints.
    final tile = ExcludeSemantics(child: _tile(context));
    final label = raftText(context, busy ? busyLabel : uploadLabel);
    return RaftTooltip(
      message: label,
      child: Opacity(
        opacity: busy ? .7 : 1,
        child: RaftInteractive(
          semanticLabel: label,
          onPressed: busy ? null : onUpload,
          builder: (context, state) {
            final active = state.hovered || state.focusVisible;
            return Stack(
              fit: StackFit.passthrough,
              children: [
                tile,
                if (active && !busy)
                  Positioned.fill(
                    child: Padding(
                      padding: RaftTokens.of(context).brutal
                          ? EdgeInsets.zero
                          : const EdgeInsets.all(2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x66000000),
                          shape: RaftTokens.of(context).brutal
                              ? BoxShape.rectangle
                              : BoxShape.circle,
                        ),
                        child: const Center(
                          child: RaftIcon(
                            RaftGlyph.upload,
                            size: 18,
                            color: Color(0xFFFFFFFF),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tile(BuildContext context) {
    final t = RaftTokens.of(context);
    Widget image(Widget fallback) => imageUrl == null
        ? fallback
        : RaftSizedImage.avatar(
            imageUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
    if (!t.brutal) {
      // Elegant Avatar (human recipe): `border-2 border-transparent
      // bg-clip-padding`, the `rounded-full bg-fill-muted` fallback whose
      // `text-sm text-foreground-placeholder/70` wins over the slot's
      // text-2xl (font-display bold carries through).
      return SizedBox.square(
        dimension: 64,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.colors['fill-muted'],
              shape: BoxShape.circle,
            ),
            child: ClipOval(
              child: image(
                Center(
                  child: Text(
                    initial,
                    style:
                        RaftTypography.heading(
                          t,
                          size: 14,
                          line: 20,
                          weight: FontWeight.w700,
                        ).copyWith(
                          color: t.colors['foreground-placeholder']!.withValues(
                            alpha: t.colors['foreground-placeholder']!.a * .7,
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: t.brutal
            ? t.colors['color-soft-signal']
            : t.colors['fill-muted'],
        border: Border.all(color: RaftSettingsText(t).edge, width: 2),
      ),
      child: image(
        Center(
          child: Text(
            initial,
            style: RaftTypography.heading(
              t,
              size: 24,
              line: 32,
              weight: FontWeight.w700,
            ).copyWith(color: RaftSettingsText(t).strong),
          ),
        ),
      ),
    );
  }
}

/// SettingsPanel.tsx preference block (`space-y-3`): a `text-sm font-bold`
/// title, a `text-xs` muted description (`mt-0.5`), an optional notice
/// (`mt-1 text-xs font-bold text-warning-strong
/// theme-brutal:text-brutal-orange`), then the control 12px below and an
/// optional error under it.
class RaftSettingsPreference extends StatelessWidget {
  const RaftSettingsPreference({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.notice,
    this.error,
    this.gapBefore = 0,
  });
  final String title;
  final String? description, notice, error;
  final Widget child;

  /// Space above the block (the form's `space-y-4` between blocks).
  final double gapBefore;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), text = RaftSettingsText(t);
    return Padding(
      padding: EdgeInsets.only(top: gapBefore),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(raftText(context, title), style: text.title),
          if (description case final description?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                raftText(context, description),
                style: text.description,
              ),
            ),
          if (notice case final notice?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                raftText(context, notice),
                style: text.description.copyWith(
                  fontWeight: FontWeight.w700,
                  color: t.brutal
                      ? t.colors['color-brutal-orange']
                      : t.colors['warning-strong'],
                ),
              ),
            ),
          const SizedBox(height: 12),
          child,
          if (error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(raftText(context, error), style: text.alert),
              ),
            ),
        ],
      ),
    );
  }
}

/// SettingsPanel success note: `border border-line-muted theme-brutal:border-2 theme-brutal:border-black
/// bg-brutal-lime/30 p-2 text-xs font-bold` (the "Password updated!" line).
class RaftSettingsSavedNote extends StatelessWidget {
  const RaftSettingsSavedNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          t.product.brutalLime.withValues(alpha: .3),
          t.brutal ? const Color(0xFFFFFFFF) : t.panel,
        ),
        border: Border.all(
          color: t.brutal ? const Color(0xFF000000) : t.semantic.lineMuted,
          width: t.brutal ? 2 : 1,
        ),
      ),
      child: Text(text, style: RaftTypography.heading(t, size: 12, line: 16)),
    );
  }
}
