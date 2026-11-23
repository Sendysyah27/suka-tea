import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// TapFeedback — pembungkus tap yang memberi animasi tekan (mengecil
/// ~0.96) + suara klik sistem, TANPA mengubah aksi, geometri, atau
/// ukuran child.
///
/// Cara kerja: Listener pointer (BUKAN GestureDetector) — jadi widget ini
/// tidak ikut arena gesture dan tidak pernah mencuri atau menggandakan
/// tap child (InkWell / FilledButton / ChoiceChip tetap yang menjalankan
/// aksinya). Skala digerakkan pointer down/up/cancel; suara dimainkan
/// saat pointer naik di dalam batas widget (tap yang batal karena jari
/// digeser keluar = tanpa suara, tanpa aksi).
///
/// Aman ditekan berulang cepat: tanpa await, tanpa state yang menumpuk,
/// AnimatedScale hanya menganimasikan ke target terbaru.
/// Aman di flutter_test: SystemSound.play melempar MissingPluginException
/// bila tidak ada platform handler — error ditelan supaya tes tidak gagal.
class TapFeedback extends StatefulWidget {
  const TapFeedback({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressedScale = 0.96,
    this.duration = const Duration(milliseconds: 140),
  });

  /// Widget yang dibungkus (tombol / tab / stepper). Aksinya tetap
  /// milik child — TapFeedback hanya menambah skala + suara.
  final Widget child;

  /// Samakan dengan kondisi aktif child (mis. tombol Bayar nonaktif
  /// saat keranjang kosong) — bila false, tidak ada skala maupun suara.
  final bool enabled;

  /// Skala saat ditekan (default 0.96).
  final double pressedScale;

  /// Durasi animasi mengecil + kembali (default 140ms, easeOutCubic —
  /// sedikit lebih lambat + lebih halus dari 120ms easeOut v18).
  final Duration duration;

  /// Suara klik sistem (SystemSoundType.click — tanpa dependensi audio,
  /// tanpa file aset suara). Aman dipanggil berkali-kali cepat.
  static void playClick() {
    try {
      SystemSound.play(SystemSoundType.click).catchError((Object _) {});
    } catch (_) {
      // Abaikan: suara tidak kritis (mis. platform tanpa handler).
    }
  }

  @override
  State<TapFeedback> createState() => _TapFeedbackState();
}

class _TapFeedbackState extends State<TapFeedback> {
  var _pressed = false;
  var _pointersDown = 0;

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    _pointersDown++;
    if (!_pressed) setState(() => _pressed = true);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!widget.enabled) return;
    _pointersDown = _pointersDown > 0 ? _pointersDown - 1 : 0;
    if (_pointersDown == 0 && _pressed) {
      setState(() => _pressed = false);
      // Suara hanya bila jari naik di dalam batas widget (tap utuh).
      if (_isInside(event.position)) TapFeedback.playClick();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointersDown = _pointersDown > 0 ? _pointersDown - 1 : 0;
    if (_pointersDown == 0 && _pressed) setState(() => _pressed = false);
  }

  bool _isInside(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return box.paintBounds.contains(box.globalToLocal(globalPosition));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
