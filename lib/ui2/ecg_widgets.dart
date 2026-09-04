// WHOOP MG ECG — the drawn parts of the capture and detail screens. Original
// vector art (no WHOOP assets), driven by a caller-owned phase so reduced
// motion can freeze it, and two waveform painters that draw ONLY the samples
// they are handed: the live ring (a bounded preview, never persisted) and the
// saved accepted window (breaks at placeholders, never bridged).
//
// Nothing here claims a lead or a polarity: the axis is microvolts as the
// band sends them.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ecg/ecg_models.dart';
import '../ecg/ecg_waveform_buffer.dart';
import 'grammar.dart';
import 'theme.dart';

/// The band on the selected wrist, both electrode indents, and the opposite
/// hand's thumb and index finger touching them, with soft contact rings.
/// [t] is the pulse phase in [0, 1) — the SCREEN owns the clock; a frozen
/// [t] is a still illustration under reduced motion. [contact] draws the
/// fingers on the electrodes; otherwise they approach.
class EcgTouchIllustration extends StatelessWidget {
  final EcgWrist wrist;
  final double t;
  final bool contact;
  final String semanticLabel;

  const EcgTouchIllustration({
    super.key,
    required this.wrist,
    required this.t,
    required this.contact,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _TouchPainter(
            wrist: wrist,
            t: t,
            contact: contact,
            ink: p.ink,
            ink2: p.ink3,
            band: p.ink,
            accent: C.domHealth,
            skin: p.card2,
          ),
          size: const Size(double.infinity, 200),
        ),
      ),
    );
  }
}

class _TouchPainter extends CustomPainter {
  final EcgWrist wrist;
  final double t;
  final bool contact;
  final Color ink, ink2, band, accent, skin;

  _TouchPainter({
    required this.wrist,
    required this.t,
    required this.contact,
    required this.ink,
    required this.ink2,
    required this.band,
    required this.accent,
    required this.skin,
  });

  @override
  void paint(Canvas cv, Size s) {
    final w = s.width, h = s.height;
    // Mirror for the left wrist: the forearm enters from the other side.
    final mirror = wrist == EcgWrist.left;
    cv.save();
    if (mirror) {
      cv.translate(w, 0);
      cv.scale(-1, 1);
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ink2;
    final fill = Paint()..color = skin;

    // Resting forearm: a rounded slab from the left edge to the wrist.
    final armTop = h * .42, armBot = h * .70;
    final armEnd = w * .58;
    final arm = RRect.fromLTRBR(
      -20,
      armTop,
      armEnd,
      armBot,
      Radius.circular((armBot - armTop) / 2),
    );
    cv.drawRRect(arm, fill);
    cv.drawRRect(arm, stroke);

    // The band around the wrist, with its two electrode indents on the
    // outer face (top and bottom edges of the strap).
    final bx = w * .46, bw = w * .07;
    final bandRect = RRect.fromLTRBR(
      bx,
      armTop - 6,
      bx + bw,
      armBot + 6,
      const Radius.circular(6),
    );
    cv.drawRRect(bandRect, Paint()..color = band);
    final electrodePaint = Paint()..color = accent;
    final e1 = Offset(bx + bw / 2, armTop - 6);
    final e2 = Offset(bx + bw / 2, armBot + 6);
    cv.drawCircle(e1, 4, electrodePaint);
    cv.drawCircle(e2, 4, electrodePaint);

    // Opposite hand: thumb from above, index finger from below, meeting the
    // two indents. Before contact they hover at a small gap that eases in
    // with the phase.
    final gap = contact ? 0.0 : 10.0 + 6.0 * math.sin(t * 2 * math.pi);
    final finger = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..color = skin;
    final fingerLine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..color = ink2
      ..strokeWidth = 16;
    // Thumb.
    final thumbTip = Offset(e1.dx, e1.dy - 8 - gap);
    final thumbBase = Offset(w * .82, h * .08);
    cv.drawLine(thumbBase, thumbTip, fingerLine);
    cv.drawLine(thumbBase, thumbTip, finger);
    // Index finger.
    final indexTip = Offset(e2.dx, e2.dy + 8 + gap);
    final indexBase = Offset(w * .86, h * .95);
    cv.drawLine(indexBase, indexTip, fingerLine);
    cv.drawLine(indexBase, indexTip, finger);

    // Contact rings: gentle pulses out of each electrode.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = accent.withValues(alpha: (1 - t) * .8);
    final r = 6 + 16 * t;
    cv.drawCircle(e1, r, ringPaint);
    cv.drawCircle(e2, r, ringPaint);
    cv.restore();
  }

  @override
  bool shouldRepaint(_TouchPainter o) =>
      o.t != t || o.contact != contact || o.wrist != wrist || o.ink != ink;
}

/// The live preview: the newest few seconds of real samples, a stable
/// symmetric range, one repaint per scheduler tick. Labelled as a preview —
/// it is not the reading and not an analysis.
class EcgLivePreview extends StatelessWidget {
  final EcgWaveformBuffer buffer;
  final EcgPreviewScheduler scheduler;
  final String label;
  final String unit;

  const EcgLivePreview({
    super.key,
    required this.buffer,
    required this.scheduler,
    required this.label,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Semantics(
      label: label,
      child: Surface(
        pad: const EdgeInsets.all(S.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: F.cap.copyWith(color: p.ink3)),
                ),
                Text(unit, style: F.cap.copyWith(color: p.ink3)),
              ],
            ),
            const SizedBox(height: S.x2),
            SizedBox(
              height: 96,
              child: RepaintBoundary(
                child: _SchedulerRepaint(
                  scheduler: scheduler,
                  builder: (_) => CustomPaint(
                    painter: EcgLivePainter(
                      buffer: buffer,
                      version: buffer.version,
                      color: C.domHealth,
                      grid: p.line,
                    ),
                    size: Size.infinite,
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

/// Rebuilds its child when the scheduler ticks (and only then).
class _SchedulerRepaint extends StatefulWidget {
  final EcgPreviewScheduler scheduler;
  final WidgetBuilder builder;
  const _SchedulerRepaint({required this.scheduler, required this.builder});

  @override
  State<_SchedulerRepaint> createState() => _SchedulerRepaintState();
}

class _SchedulerRepaintState extends State<_SchedulerRepaint> {
  @override
  void initState() {
    super.initState();
    widget.scheduler.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.scheduler.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Symmetric ±range in µV for a window whose largest magnitude is [maxAbs]:
/// stepped so it does not jitter packet to packet, never below the floor.
int ecgPreviewRange(int maxAbs, {int step = 250, int floor = 500}) {
  final stepped = ((maxAbs + step - 1) ~/ step) * step;
  return math.max(floor, stepped);
}

class EcgLivePainter extends CustomPainter {
  final EcgWaveformBuffer buffer;
  final int version;
  final Color color;
  final Color grid;

  EcgLivePainter({
    required this.buffer,
    required this.version,
    required this.color,
    required this.grid,
  });

  @override
  void paint(Canvas cv, Size s) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    cv.drawLine(
      Offset(0, s.height / 2),
      Offset(s.width, s.height / 2),
      gridPaint,
    );
    final n = buffer.length;
    if (n < 2 || s.width <= 0) return;
    final range = ecgPreviewRange(buffer.maxAbs()).toDouble();
    final cap = buffer.capacity;
    // The window is the ring's capacity; a partly-filled ring draws from the
    // right so the trace scrolls in rather than stretching.
    final dx = s.width / (cap - 1);
    final x0 = s.width - (n - 1) * dx;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final v = buffer[i].clamp(-range, range);
      final y = s.height / 2 - v / range * (s.height / 2 - 2);
      final x = x0 + i * dx;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    cv.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(EcgLivePainter o) =>
      o.version != version || o.buffer != buffer || o.color != color;
}

/// The complete accepted window of a saved reading. A placeholder packet is
/// a visible break — a one-second hole in the trace, never a line across it.
/// Horizontal scale is [pxPerSecond]; the caller wraps it in a horizontal
/// scroll view at the width [widthFor] reports.
class EcgWaveformPainter extends CustomPainter {
  final List<EcgAcceptedPacket> packets;
  final double pxPerSecond;
  final Color color;
  final Color grid;
  final Color gap;

  EcgWaveformPainter({
    required this.packets,
    required this.pxPerSecond,
    required this.color,
    required this.grid,
    required this.gap,
  });

  /// One second per packet (100 samples at 100 Hz), placeholders included.
  static double widthFor(List<EcgAcceptedPacket> packets, double pxPerSecond) =>
      math.max(1, packets.length) * pxPerSecond;

  static int rangeFor(List<EcgAcceptedPacket> packets) {
    var m = 0;
    for (final p in packets) {
      for (final v in p.samples) {
        if (v.abs() > m) m = v.abs();
      }
    }
    return ecgPreviewRange(m);
  }

  @override
  void paint(Canvas cv, Size s) {
    if (packets.isEmpty) return;
    final range = rangeFor(packets).toDouble();
    final mid = s.height / 2;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // One-second grid.
    for (var i = 0; i <= packets.length; i++) {
      final x = i * pxPerSecond;
      cv.drawLine(Offset(x, 0), Offset(x, s.height), gridPaint);
    }
    cv.drawLine(Offset(0, mid), Offset(s.width, mid), gridPaint);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final gapPaint = Paint()..color = gap;
    var x = 0.0;
    Path? path;
    for (final p in packets) {
      if (p.placeholder || p.samples.isEmpty) {
        // Break the trace and wash the missing second.
        if (path != null) cv.drawPath(path, stroke);
        path = null;
        cv.drawRect(Rect.fromLTWH(x, 0, pxPerSecond, s.height), gapPaint);
        x += pxPerSecond;
        continue;
      }
      final n = p.samples.length;
      final dx = pxPerSecond / kEcgSampleRateHz;
      for (var i = 0; i < n; i++) {
        final v = p.samples[i].clamp(-range, range);
        final y = mid - v / range * (mid - 2);
        final px = x + i * dx;
        if (path == null) {
          path = Path()..moveTo(px, y);
        } else {
          path.lineTo(px, y);
        }
      }
      x += pxPerSecond;
    }
    if (path != null) cv.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(EcgWaveformPainter o) =>
      o.packets != packets || o.pxPerSecond != pxPerSecond || o.color != color;
}
