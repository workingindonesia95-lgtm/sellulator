import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'nav.dart';
import 'settings.dart' show kAppVersion;

/// Isi dengan URL Web App Apps Script (berakhiran /exec).
const kUpdateEndpoint =
    'https://script.google.com/macros/s/AKfycbxB1rWAu5MogHsgsfRBuoY28h-iWlAuxe_JsSye01kgjczshoboovjCF10BZRqYpdHJ/exec';

class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.url,
    required this.size,
    required this.sha256,
    required this.notes,
    required this.minVersion,
  });

  final String version;
  final String url;
  final int size;
  final String? sha256;
  final String notes;
  final String minVersion;

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
    version: j['version'] as String,
    url: j['url'] as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
    sha256: j['sha256'] as String?,
    notes: (j['notes'] as String?) ?? '',
    minVersion: (j['minVersion'] as String?) ?? '0.0.0',
  );
}

/// Bandingkan "1.2.3" vs "1.10.0". Hasil >0 bila [a] lebih baru dari [b].
int compareVersions(String a, String b) {
  List<int> parse(String v) => v
      .split('+')
      .first
      .split('-')
      .first
      .split('.')
      .map((s) => int.tryParse(s) ?? 0)
      .toList();
  final x = parse(a), y = parse(b);
  for (var i = 0; i < 3; i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi.compareTo(yi);
  }
  return 0;
}

class Updater {
  Updater._();

  static String get currentVersion => kAppVersion;

  static Future<UpdateInfo> fetchLatest() async {
    final res = await http
        .get(Uri.parse(kUpdateEndpoint))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Server membalas ${res.statusCode}');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception(j['error']);
    return UpdateInfo.fromJson(j);
  }

  /// Unduh zip ke folder sementara, lalu cocokkan SHA-256 bila tersedia.
  static Future<File> download(
    UpdateInfo info,
    void Function(double) onProgress,
  ) async {
    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'sellulator_update'));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    final file = File(p.join(work.path, 'update.zip'));
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(info.url)));
      if (resp.statusCode != 200) {
        throw Exception('Unduhan gagal (${resp.statusCode})');
      }
      final total = resp.contentLength ?? info.size;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress((got / total).clamp(0.0, 1.0));
      }
      await sink.close();
    } finally {
      client.close();
    }

    if (info.sha256 != null && info.sha256!.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != info.sha256!.toLowerCase()) {
        throw Exception('File rusak: checksum SHA-256 tidak cocok.');
      }
    }
    return file;
  }

  /// Ekstrak zip, lalu jalankan skrip .bat yang menunggu app tertutup,
  /// menimpa file di folder instalasi, dan membuka app lagi. Lalu app keluar.
  static Future<void> installAndRestart(File zip) async {
    final out = Directory(p.join(zip.parent.path, 'extracted'));
    if (await out.exists()) await out.delete(recursive: true);
    await extractFileToDisk(zip.path, out.path);

    final exePath = Platform.resolvedExecutable;
    final exeName = p.basename(exePath);
    final installDir = p.dirname(exePath);
    final srcDir = _findRoot(out, exeName);

    final bat = File(p.join(zip.parent.path, 'apply_update.bat'));
    await bat.writeAsString('''
@echo off
set tries=0
:retry
timeout /t 2 /nobreak >nul
xcopy "$srcDir\\*" "$installDir\\" /E /Y /I /Q >nul
if not errorlevel 1 goto done
set /a tries+=1
if %tries% LSS 10 goto retry
exit /b 1
:done
start "" "$exePath"
exit /b 0
''');

    await Process.start('cmd.exe', [
      '/c',
      bat.path,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Folder di dalam hasil ekstrak yang berisi file .exe (zip bisa punya
  /// folder pembungkus atau tidak).
  static String _findRoot(Directory out, String exeName) {
    if (File(p.join(out.path, exeName)).existsSync()) return out.path;
    for (final e in out.listSync(recursive: true)) {
      if (e is File && p.basename(e.path) == exeName) return e.parent.path;
    }
    throw Exception('$exeName tidak ditemukan di dalam zip pembaruan.');
  }

  // ---------------------------------------------------------------- UI

  /// Cek ke server. Mengembalikan info bila ada versi lebih baru, null bila
  /// sudah terbaru. Melempar exception bila gagal.
  static Future<UpdateInfo?> check() async {
    final info = await fetchLatest();
    return compareVersions(info.version, currentVersion) > 0 ? info : null;
  }

  /// Tampilkan dialog pembaruan (dengan unduh + pasang otomatis).
  static void showUpdate(UpdateInfo info) {
    final cur = currentVersion;
    final force = compareVersions(cur, info.minVersion) < 0;
    _push(
      (_) => UpdateDialog(info: info, current: cur, force: force),
      dismissible: !force,
    );
  }

  /// Dipanggil otomatis saat app dibuka: diam bila sudah terbaru / gagal.
  static Future<void> checkOnStartup() async {
    if (!Platform.isWindows) return;
    try {
      final info = await check();
      if (info != null) showUpdate(info);
    } catch (_) {}
  }

  static void _push(WidgetBuilder builder, {bool dismissible = true}) {
    final nav = appNavKey.currentState;
    final ctx = appNavKey.currentContext;
    if (nav == null || ctx == null) return;
    nav.push(
      DialogRoute<void>(
        context: ctx,
        barrierDismissible: dismissible,
        builder: builder,
      ),
    );
  }
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.info,
    required this.current,
    required this.force,
  });
  final UpdateInfo info;
  final String current;
  final bool force;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _busy = false;
  double _progress = 0;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      final zip = await Updater.download(
        widget.info,
        (v) => setState(() => _progress = v),
      );
      await Updater.installAndRestart(zip);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return PopScope(
      canPop: !widget.force && !_busy,
      child: AlertDialog(
        title: Text(widget.force ? 'Pembaruan wajib' : 'Pembaruan tersedia'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('v${widget.current}  →  v${info.version}'),
              if (info.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Yang baru:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: SingleChildScrollView(child: Text(info.notes.trim())),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                ),
                const SizedBox(height: 6),
                Text('Mengunduh… ${(_progress * 100).toStringAsFixed(0)}%'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
        actions: [
          if (!widget.force && !_busy)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Nanti'),
            ),
          FilledButton(
            onPressed: _busy ? null : _run,
            child: Text(_error != null ? 'Coba lagi' : 'Perbarui sekarang'),
          ),
        ],
      ),
    );
  }
}
