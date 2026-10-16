"""Windows SDK launch after the official entrypoint has bootstrapped it."""
import os
from pathlib import Path


def windows_arguments(value):
    """Parse FLUTTER_TOOL_ARGS as Windows argv, including quoted SDK paths."""
    if not value.strip():
        return []
    import ctypes
    from ctypes import wintypes

    parse = ctypes.WinDLL('shell32', use_last_error=True).CommandLineToArgvW
    parse.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    parse.restype = ctypes.POINTER(wintypes.LPWSTR)
    free = ctypes.WinDLL('kernel32', use_last_error=True).LocalFree
    free.argtypes = [wintypes.HLOCAL]
    free.restype = wintypes.HLOCAL
    count = ctypes.c_int()
    arguments = parse(f'dart {value}', ctypes.byref(count))
    if not arguments:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return [arguments[index] for index in range(1, count.value)]
    finally:
        free(ctypes.cast(arguments, wintypes.HLOCAL))


def windows_sdk_command(executable, arguments, environment):
    """Match pinned flutter.bat's final Dart command without cmd.exe's 8K limit.

    The caller must first run flutter.bat --version --machine successfully:
    that official short command owns SDK installation, locking and snapshot
    rebuilding. Custom launchers without this SDK layout retain their entrypoint.
    """
    executable = Path(executable).absolute()
    sdk = executable.parent.parent
    dart = sdk / 'bin/cache/dart-sdk/bin/dart.exe'
    snapshot = sdk / 'bin/cache/flutter_tools.snapshot'
    packages = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    child_env = dict(environment)
    if (executable.name.lower() != 'flutter.bat'
            or executable.parent.name.lower() != 'bin'
            or not all(path.is_file() for path in (dart, snapshot, packages))):
        return [str(executable), *arguments], child_env

    # flutter.bat uses SETLOCAL, so its SDK root and bundled Git do not survive
    # the bootstrap process. Reproduce those two settings for the native launch.
    child_env['FLUTTER_ROOT'] = str(sdk)
    mingit = sdk / 'bin/mingit/cmd'
    if mingit.is_dir():
        child_env['PATH'] = child_env.get('PATH', '') + os.pathsep + str(mingit)
    return [str(dart), f'--packages={packages}',
            *windows_arguments(child_env.get('FLUTTER_TOOL_ARGS', '')),
            str(snapshot), *arguments], child_env
