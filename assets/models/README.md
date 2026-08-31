# mobilefacenet.tflite

Present. Sourced from
[MCarlomagno/FaceRecognitionAuth](https://github.com/MCarlomagno/FaceRecognitionAuth/blob/master/assets/mobilefacenet.tflite)
(BSD-3-Clause, Copyright (c) 2020 Marcos Carlomagno — see that repo's
`LICENSE` for the full text, reproduced here as attribution for this
redistributed file).

Verified before use:
- File starts with the `TFL3` FlatBuffer magic bytes — a genuine TFLite
  model, not an HTML error page or truncated download.
- ~5.2MB, consistent with the expected MobileFaceNet size.
- Source repo confirmed BSD-3-Clause licensed (permissive, redistribution
  allowed).

Model spec (per the source project's documentation, matched in
`FaceEmbeddingService`):
- Input: `[1, 112, 112, 3]` float32, normalized to roughly `[-1, 1]`
  (`(pixel - 127.5) / 128.0` per channel).
- Output: `[1, 192]` float32 — a 192-dimensional embedding (not the 128-d
  more commonly quoted for MobileFaceNet in papers — this specific
  converted file outputs 192).

**Important**: `Interpreter.fromAsset()` (tflite_flutter) calls
`rootBundle.load()` directly, so it needs the *full* asset key exactly as
declared in `pubspec.yaml` — `'assets/models/mobilefacenet.tflite'`, not
that path with the `assets/` prefix stripped off (which just looks like a
missing-asset error at runtime instead of a wrong-path one).
