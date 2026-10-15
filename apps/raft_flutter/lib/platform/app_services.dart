import 'package:flutter/widgets.dart';

import 'app_update.dart';

/// Stable application services. Account and server state have their own owners.
@immutable
class AppServices {
  const AppServices.withUpdates(AppUpdateService update) : appUpdate = update;

  /// Explicit opt-out for isolated component tests and previews.
  const AppServices.updatesDisabledForTestOrPreview() : appUpdate = null;

  final AppUpdateService? appUpdate;
}

/// Place above Navigator so routes, dialogs and overlays share the same values.
/// Service state is observed by its consumers, not by this inherited widget.
class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });
  final AppServices services;

  static AppServices? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppServicesScope>()?.services;

  static AppServices of(BuildContext context) {
    final services = maybeOf(context);
    if (services == null) {
      throw FlutterError(
        'AppServicesScope is missing. Install it above Navigator; '
        'tests and previews must explicitly declare disabled updates.',
      );
    }
    return services;
  }

  @override
  bool updateShouldNotify(AppServicesScope oldWidget) =>
      !identical(services.appUpdate, oldWidget.services.appUpdate);
}

/// The root may own the update service; borrowed roots and pages never release it.
class AppServicesHost extends StatefulWidget {
  const AppServicesHost({
    super.key,
    required this.services,
    this.ownsAppUpdate = false,
    required this.child,
  });
  final AppServices services;
  final bool ownsAppUpdate;
  final Widget child;

  @override
  State<AppServicesHost> createState() => _AppServicesHostState();
}

class _AppServicesHostState extends State<AppServicesHost> {
  final _retired = <AppUpdateService>{};

  @override
  void didUpdateWidget(AppServicesHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.services.appUpdate;
    if (oldWidget.ownsAppUpdate &&
        previous != null &&
        !identical(previous, widget.services.appUpdate)) {
      _retired.add(previous);
      // Descendant consumers release their old listeners during this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseRetired());
    }
    _retired.remove(widget.services.appUpdate);
  }

  void _releaseRetired({bool keepCurrent = true}) {
    if (keepCurrent && mounted) _retired.remove(widget.services.appUpdate);
    final retired = _retired.toList();
    _retired.clear();
    for (final service in retired) {
      service.dispose();
    }
  }

  @override
  Widget build(BuildContext context) =>
      AppServicesScope(services: widget.services, child: widget.child);

  @override
  void dispose() {
    if (widget.ownsAppUpdate && widget.services.appUpdate != null) {
      _retired.add(widget.services.appUpdate!);
    }
    _releaseRetired(keepCurrent: false);
    super.dispose();
  }
}
