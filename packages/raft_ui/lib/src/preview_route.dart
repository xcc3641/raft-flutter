import 'package:flutter/material.dart';

/// Marks a content preview that closes before the containing desktop window.
///
/// A preview can be a page route on compact windows and still keep this policy
/// after the window grows. Ordinary navigation pages do not carry this marker.
abstract interface class RaftPreviewRoute {}

/// Presents a document preview as a page while retaining preview close behavior.
class RaftPreviewPageRoute<T> extends MaterialPageRoute<T>
    implements RaftPreviewRoute {
  RaftPreviewPageRoute({required super.builder, super.settings});
}
