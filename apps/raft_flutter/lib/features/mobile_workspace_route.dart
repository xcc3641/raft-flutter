part of 'workspace_view.dart';

/// Data notifications reach the live page's controller. Only history or
/// authority changes need to reconcile the Navigator's page configuration.
class _MobileNavigationSelection extends ChangeNotifier {
  _MobileNavigationSelection(this.host) : source = host.w {
    inputs = read();
    source.addListener(changed);
  }
  final _WorkspaceViewState host;
  final WorkspaceController source;
  late Object inputs;

  Object read() {
    host.updateChannelAuthority();
    return (
      host.desktopAuthority,
      source.location,
      source.navigation.revision,
      source.navigation.taskRevision,
      source.navigation.index,
      host.mobileTabIds.join(','),
    );
  }

  void changed() {
    final next = read();
    if (next == inputs) return;
    inputs = next;
    notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(changed);
    super.dispose();
  }
}

/// A live widget tree per platform route, borrowing the workspace's accepted
/// data. Historical routes keep their location, not an image of the page.
class _MobileWorkspaceRoute extends StatefulWidget {
  const _MobileWorkspaceRoute({required this.host, required this.location});
  final _WorkspaceViewState host;
  final RaftLocation location;
  @override
  State<_MobileWorkspaceRoute> createState() => _MobileWorkspaceRouteState();
}

class _MobileWorkspaceRouteState extends State<_MobileWorkspaceRoute> {
  late final _MobilePageController controller;
  Widget? content;
  WorkspaceController get source => widget.host.w;
  bool get active =>
      mobilePageIdentity(source.location) ==
      mobilePageIdentity(widget.location);

  @override
  void initState() {
    super.initState();
    controller = _MobilePageController(source, widget.location);
    controller.synchronizePagePresentation(source, active: true);
    synchronize();
    source.addListener(sourceChanged);
  }

  void synchronize() {
    if (active) {
      controller.navigation.projectHistory(source.navigation, source.location);
    }
    controller.synchronizePagePresentation(source, active: active);
  }

  void sourceChanged() {
    synchronize();
    if (active) controller.notifyListeners();
  }

  @override
  void didUpdateWidget(_MobileWorkspaceRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    synchronize();
  }

  @override
  void dispose() {
    source.removeListener(sourceChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    if (content == null || active) {
      content = _MobileWorkspaceContent(
        controller: controller,
        mobileHost: host,
        appearance: host.widget.appearance,
        onAppearance: host.widget.onAppearance,
        onLogout: host.widget.onLogout,
        notifications: host.widget.notifications,
        sharing: host.widget.sharing,
        presentation: host.presentation,
        mobileTabbar: host.mobileTabbar,
        railSide: host.railSideStore,
        onChooseServer: host.widget.onChooseServer,
        onSwitchServer: host.widget.onSwitchServer,
      );
    }
    return IgnorePointer(
      ignoring: !active,
      child: ExcludeSemantics(
        excluding: !active,
        child: RouteFrameDiagnostics.enabled
            ? RouteFrameProbe(child: content)
            : content!,
      ),
    );
  }
}

class _MobileWorkspaceContent extends WorkspaceView {
  const _MobileWorkspaceContent({
    required super.controller,
    required super.appearance,
    required super.onAppearance,
    required super.onLogout,
    required super.mobileHost,
    super.notifications,
    super.sharing,
    super.presentation,
    super.mobileTabbar,
    super.railSide,
    super.onChooseServer,
    super.onSwitchServer,
  }) : super(mobileRoutePage: true);
}

class _MobilePageController extends WorkspaceController {
  _MobilePageController(WorkspaceController source, RaftLocation location)
    : pageNavigation = _MobilePageNavigation(source, location),
      super(
        source.client,
        cache: source.cache,
        presentationSource: source,
        ownsClient: false,
        mobileNavigation: true,
        restoreSharedAttachment: source.restoreSharedAttachment,
        discardSharedScope: source.discardSharedScope,
        entityDirectory: source.entityDirectory,
        followedThreads: source.followedThreads,
        attachmentImageStore: source.attachmentImageStore,
        composer: source.composer,
      );
  final _MobilePageNavigation pageNavigation;
  @override
  WorkspaceNavigation get navigation => pageNavigation;
  @override
  void bindNavigation() {}
}

class _MobilePageNavigation extends WorkspaceNavigation {
  _MobilePageNavigation(this.source, RaftLocation location)
    : super(initial: location) {
    projectHistory(source.navigation, location);
  }
  final WorkspaceController source;
  @override
  bool replaceSearchQuery(String committed) {
    final changed = source.navigation.replaceSearchQuery(committed);
    if (changed) source.notifyListeners();
    return changed;
  }

  @override
  void navigate(
    RaftLocation next, {
    RaftNavigationKind kind = RaftNavigationKind.push,
  }) {
    source.navigation.navigate(next, kind: kind);
    source.notifyListeners();
  }

  @override
  void navigateTask(
    RaftLocation next, {
    RaftNavigationKind kind = RaftNavigationKind.push,
  }) {
    source.navigation.navigateTask(next, kind: kind);
    source.notifyListeners();
  }

  @override
  RaftLocation back() {
    final next = source.navigation.back();
    source.notifyListeners();
    return next;
  }
}
