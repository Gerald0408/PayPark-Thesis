import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Shows a captured document photo from whichever source is actually
/// available on this device: the local file first (fastest, no network
/// needed — this is the device that captured it, or the file happens to
/// still be cached here), falling back to the synced Firebase Storage
/// [url] (see VehicleDocumentStorage) so a document captured on a
/// *different* device still shows up instead of a broken-image icon.
/// Falls through to [placeholder] only when neither source is available
/// at all (never captured, or captured offline and never synced).
class DocPhotoView extends StatelessWidget {
  const DocPhotoView({
    super.key,
    required this.path,
    required this.url,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final String? path;
  final String? url;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final localPath = path;
    if (localPath != null && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        fit: fit,
        errorBuilder: (_, __, ___) => _networkOrPlaceholder(),
      );
    }
    return _networkOrPlaceholder();
  }

  Widget _networkOrPlaceholder() {
    final remoteUrl = url;
    if (remoteUrl == null) return _placeholder();
    return Image.network(
      remoteUrl,
      fit: fit,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Center(
              child: CircularProgressIndicator(
                  color: YosColors.accent, strokeWidth: 2)),
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() =>
      placeholder ??
      Container(
        color: YosColors.surfaceHigh,
        alignment: Alignment.center,
        child: Icon(Icons.image_not_supported_outlined,
            color: YosColors.sub, size: 28),
      );
}
