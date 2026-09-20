import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../core/theme.dart';
import '../services/vehicle_document_cache.dart';
import '../services/vehicle_document_storage.dart';

/// Shows a captured document from whichever source is actually available
/// on this device: the local file first (fastest, no network needed —
/// this is the device that captured it, or the file happens to still be
/// cached here), falling back to the synced Firebase Storage [url] (see
/// VehicleDocumentStorage) so a document captured on a *different* device
/// still shows up instead of a broken-image icon. Falls through to
/// [placeholder] only when neither source is available at all (never
/// captured, or captured offline and never synced).
///
/// A captured document is a one-page PDF now (see DocumentPdf) — a real,
/// self-contained file rather than a bare photo tied to this one screen's
/// own rendering — rendered here via [PdfPreview]. [path]/[url] ending in
/// anything other than `.pdf` are still shown as a plain image, so an
/// older local-only capture that predates the PDF switch keeps working.
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

  /// True when [path]/[url] is a PDF document rather than a plain image —
  /// exposed so a full-screen "View" host can skip wrapping this in its
  /// own zoom gesture handling: [PdfPreview] already provides pinch-to-
  /// zoom internally (its own nested InteractiveViewer), and a second one
  /// wrapped around it would fight the first over the same gestures.
  static bool isPdfSource(String? path, String? url) =>
      (path?.toLowerCase().endsWith('.pdf') ?? false) ||
      (url?.toLowerCase().contains('.pdf') ?? false);

  bool get _isPdf => isPdfSource(path, url);

  @override
  Widget build(BuildContext context) {
    if (_isPdf) {
      return _PdfFileView(path: path, url: url, placeholder: _placeholder());
    }
    final localKey = path;
    if (localKey != null) {
      // Hive first (every capture since VehicleDocumentCache shipped),
      // falling back to a plain file (a legacy capture whose stored
      // "path" is still a real filesystem path from before Hive existed
      // — see VehicleDocumentStorage.fetchBytes's matching fallback).
      final cached = VehicleDocumentCache.instance.read(localKey);
      if (cached != null) {
        return Image.memory(
          cached,
          fit: fit,
          errorBuilder: (_, __, ___) => _networkOrPlaceholder(),
        );
      }
      if (File(localKey).existsSync()) {
        return Image.file(
          File(localKey),
          fit: fit,
          errorBuilder: (_, __, ___) => _networkOrPlaceholder(),
        );
      }
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

/// Renders a PDF document from a local file or, failing that, a
/// downloaded copy of [url]'s bytes — [PdfPreview] needs the actual bytes
/// up front, unlike [Image.network]'s built-in URL loading.
class _PdfFileView extends StatelessWidget {
  const _PdfFileView({required this.path, required this.url, required this.placeholder});

  final String? path;
  final String? url;
  final Widget placeholder;

  Future<Uint8List> _load(_) async {
    final bytes = await VehicleDocumentStorage.instance.fetchBytes(path: path, url: url);
    if (bytes == null) {
      throw StateError('No local file or Storage URL to load a PDF from.');
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    if (path == null && url == null) return placeholder;
    return PdfPreview(
      build: _load,
      useActions: false,
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      allowPrinting: false,
      allowSharing: false,
      scrollViewDecoration: const BoxDecoration(),
      previewPageMargin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      loadingWidget: Center(
          child: CircularProgressIndicator(
              color: YosColors.accent, strokeWidth: 2)),
      onError: (context, error) => placeholder,
    );
  }
}
