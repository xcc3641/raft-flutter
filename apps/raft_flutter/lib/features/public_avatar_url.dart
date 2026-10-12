/// Resolves only public avatar surfaces against the active API origin.
/// Source app.ts mounts avatars and external-avatars without authentication;
/// provider/CDN absolute HTTP URLs retain their own origin and receive no token.
String? raftPublicAvatarUrl(String origin, String? value) {
  if (value == null || value.isEmpty) return null;
  final avatar = Uri.tryParse(value);
  if (avatar == null || avatar.userInfo.isNotEmpty) return null;
  if (avatar.hasScheme) {
    return ['http', 'https'].contains(avatar.scheme) && avatar.host.isNotEmpty
        ? value
        : null;
  }
  final path = avatar.path;
  final validPath =
      path.startsWith('/api/avatars/') ||
      path.startsWith('/avatars/') ||
      path.startsWith('/api/external-avatars/') ||
      path.startsWith('/external-avatars/');
  if (avatar.hasAuthority ||
      !validPath ||
      avatar.pathSegments.any((segment) => segment == '.' || segment == '..')) {
    return null;
  }
  final base = Uri.tryParse(origin);
  if (base == null ||
      !['http', 'https'].contains(base.scheme) ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty) {
    return null;
  }
  return base.resolveUri(avatar).toString();
}
