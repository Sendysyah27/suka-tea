import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/roles.dart';
import 'qris_scan_logic.dart';
import 'qris_scan_page.dart';
import 'qris_service.dart';
import 'qris_settings_service.dart';

/// Pengaturan QRIS Merchant — HANYA Owner.
///
/// Owner menempel (atau scan) kode QRIS statisnya. Format divalidasi
/// dasar sebelum disimpan (format indicator, CRC, mata uang IDR).
/// Nilai asli TIDAK PERNAH di-hardcode di repo; yang tampil di sini hanya
/// nama merchant + status, bukan payload mentah. Kasir tidak bisa ubah.
class QrisSettingsPage extends StatefulWidget {
  const QrisSettingsPage({super.key, required this.role});

  final AppRole role;

  @override
  State<QrisSettingsPage> createState() => _QrisSettingsPageState();
}

class _QrisSettingsPageState extends State<QrisSettingsPage> {
  final _controller = TextEditingController();
  String? _error;
  String? _savedMerchant;

  @override
  void initState() {
    super.initState();
    _savedMerchant = QrisSettingsService.instance.merchantName;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = (data?.text ?? '').trim();
    if (text.isNotEmpty) {
      setState(() => _controller.text = text);
    }
  }

  /// Buka halaman scan kamera. Hasil scan diisi ke field, lalu
  /// divalidasi seperti tempelan manual — TIDAK langsung disimpan.
  /// Bila hasil scan bukan QRIS valid, tampilkan error validasinya.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrisScanPage()),
    );
    if (raw == null || !mounted) return;
    final result = processScannedPayload(raw);
    setState(() {
      _controller.text = result.payload;
      _error = result.error;
    });
  }

  Future<void> _save() async {
    final payload = _controller.text.trim();
    final error = QrisService.validationError(payload);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await QrisSettingsService.instance.save(payload);
    if (!mounted) return;
    setState(() {
      _error = null;
      _savedMerchant = QrisService.merchantName(payload);
      _controller.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('QRIS merchant tersimpan.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.role.canManageMenu) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pengaturan QRIS')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Hanya Owner yang bisa mengatur QRIS merchant.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final configured = QrisSettingsService.instance.isConfigured;
    final merchant = _savedMerchant;
    final previewError = _controller.text.isEmpty
        ? null
        : QrisService.validationError(_controller.text.trim());

    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan QRIS')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text(
                configured
                    ? 'QRIS merchant terpasang'
                    : 'QRIS merchant belum diatur',
              ),
              subtitle: Text(
                merchant != null
                    ? 'Merchant: $merchant'
                    : 'Tempel kode QRIS statis dari merchant di bawah.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Kode QRIS statis merchant',
              hintText: 'Tempel payload QRIS (diawali 000201...)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (previewError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                previewError,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.paste),
                  label: const Text('Tempel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _save,
            child: const Text('Validasi & Simpan'),
          ),
          if (configured) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await QrisSettingsService.instance.clear();
                if (!mounted) return;
                setState(() => _savedMerchant = null);
                messenger.showSnackBar(
                  const SnackBar(content: Text('QRIS merchant dihapus.')),
                );
              },
              child: const Text('Hapus QRIS merchant'),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Validasi sebelum simpan: Payload Format Indicator "01", '
            'Point of Initiation "11"/"12", mata uang "360" (IDR), dan CRC '
            'tag 63 harus valid. Nilai asli hanya tersimpan di Supabase '
            '(app_settings, Owner-only) — tidak di repo.',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
