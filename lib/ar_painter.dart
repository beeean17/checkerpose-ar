import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ArPainter extends CustomPainter {
  const ArPainter({
    required this.posterImage,
    required this.normalizedQuad,
    required this.showPoster,
  });

  final ui.Image? posterImage;
  final List<Offset> normalizedQuad;
  final bool showPoster;

  @override
  void paint(Canvas canvas, Size size) {
    if (!showPoster || posterImage == null || normalizedQuad.length != 4) {
      return;
    }

    final rawQuad = normalizedQuad
        .map((point) => Offset(point.dx * size.width, point.dy * size.height))
        .toList(growable: false);
    final quad = _posterDestinationQuad(rawQuad);

    final shadow = Path()
      ..moveTo(quad[3].dx, quad[3].dy)
      ..lineTo(quad[2].dx, quad[2].dy)
      ..lineTo(quad[2].dx + 18, quad[2].dy + 8)
      ..lineTo(quad[3].dx + 18, quad[3].dy + 8)
      ..close();
    canvas.drawPath(
      shadow,
      Paint()..color = Colors.black.withValues(alpha: 0.20),
    );

    final transform = _buildPerspectiveTransform(
      sourceWidth: posterImage!.width.toDouble(),
      sourceHeight: posterImage!.height.toDouble(),
      destination: quad,
    );
    if (transform == null) {
      return;
    }

    canvas.save();
    canvas.clipPath(_quadPath(quad));
    canvas.transform(transform);
    canvas.drawImage(posterImage!, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ArPainter oldDelegate) {
    return oldDelegate.posterImage != posterImage ||
        oldDelegate.showPoster != showPoster ||
        oldDelegate.normalizedQuad != normalizedQuad;
  }

  Path _quadPath(List<Offset> quad) {
    return Path()
      ..moveTo(quad[0].dx, quad[0].dy)
      ..lineTo(quad[1].dx, quad[1].dy)
      ..lineTo(quad[2].dx, quad[2].dy)
      ..lineTo(quad[3].dx, quad[3].dy)
      ..close();
  }

  List<Offset> _posterDestinationQuad(List<Offset> rawQuad) {
    if (rawQuad.length != 4) {
      return rawQuad;
    }

    final center = rawQuad.reduce((sum, point) => sum + point) / 4.0;
    final ordered = List<Offset>.from(rawQuad)
      ..sort((a, b) {
        final angleA = _angleAround(center, a);
        final angleB = _angleAround(center, b);
        return angleA.compareTo(angleB);
      });

    final topLeftIndex = _indexOfMin(
      ordered.map((point) => point.dx + point.dy).toList(growable: false),
    );
    final rotated = List<Offset>.generate(
      4,
      (index) => ordered[(topLeftIndex + index) % 4],
      growable: false,
    );

    if (rotated[1].dx < rotated[3].dx) {
      return <Offset>[rotated[0], rotated[3], rotated[2], rotated[1]];
    }

    return rotated;
  }

  double _angleAround(Offset center, Offset point) {
    return (point - center).direction;
  }

  int _indexOfMin(List<double> values) {
    var index = 0;
    var minValue = values[0];
    for (var i = 1; i < values.length; i++) {
      if (values[i] < minValue) {
        minValue = values[i];
        index = i;
      }
    }
    return index;
  }

  Float64List? _buildPerspectiveTransform({
    required double sourceWidth,
    required double sourceHeight,
    required List<Offset> destination,
  }) {
    final source = <Offset>[
      const Offset(0, 0),
      Offset(sourceWidth, 0),
      Offset(sourceWidth, sourceHeight),
      Offset(0, sourceHeight),
    ];

    final matrixRows = List<List<double>>.generate(
      8,
      (_) => List<double>.filled(8, 0),
    );
    final vector = List<double>.filled(8, 0);

    for (var i = 0; i < 4; i++) {
      final x = source[i].dx;
      final y = source[i].dy;
      final u = destination[i].dx;
      final v = destination[i].dy;
      final row = i * 2;

      matrixRows[row][0] = x;
      matrixRows[row][1] = y;
      matrixRows[row][2] = 1;
      matrixRows[row][6] = -u * x;
      matrixRows[row][7] = -u * y;
      vector[row] = u;

      matrixRows[row + 1][3] = x;
      matrixRows[row + 1][4] = y;
      matrixRows[row + 1][5] = 1;
      matrixRows[row + 1][6] = -v * x;
      matrixRows[row + 1][7] = -v * y;
      vector[row + 1] = v;
    }

    final solved = _solveLinearSystem(matrixRows, vector);
    if (solved == null) {
      return null;
    }

    final storage = Float64List(16);
    storage[0] = solved[0];
    storage[4] = solved[1];
    storage[12] = solved[2];
    storage[1] = solved[3];
    storage[5] = solved[4];
    storage[13] = solved[5];
    storage[3] = solved[6];
    storage[7] = solved[7];
    storage[10] = 1;
    storage[15] = 1;
    return storage;
  }

  List<double>? _solveLinearSystem(List<List<double>> matrix, List<double> vector) {
    final n = vector.length;
    final a = matrix.map((row) => List<double>.from(row)).toList(growable: false);
    final b = List<double>.from(vector);

    for (var pivot = 0; pivot < n; pivot++) {
      var maxRow = pivot;
      var maxValue = a[pivot][pivot].abs();
      for (var row = pivot + 1; row < n; row++) {
        final value = a[row][pivot].abs();
        if (value > maxValue) {
          maxValue = value;
          maxRow = row;
        }
      }

      if (maxValue < 1e-9) {
        return null;
      }

      if (maxRow != pivot) {
        final tempRow = a[pivot];
        a[pivot] = a[maxRow];
        a[maxRow] = tempRow;

        final tempValue = b[pivot];
        b[pivot] = b[maxRow];
        b[maxRow] = tempValue;
      }

      final pivotValue = a[pivot][pivot];
      for (var col = pivot; col < n; col++) {
        a[pivot][col] /= pivotValue;
      }
      b[pivot] /= pivotValue;

      for (var row = 0; row < n; row++) {
        if (row == pivot) {
          continue;
        }
        final factor = a[row][pivot];
        if (factor == 0) {
          continue;
        }
        for (var col = pivot; col < n; col++) {
          a[row][col] -= factor * a[pivot][col];
        }
        b[row] -= factor * b[pivot];
      }
    }

    return b;
  }
}
