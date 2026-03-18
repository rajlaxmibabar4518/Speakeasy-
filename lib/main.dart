// main.dart
import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'login_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'history_screen.dart';
import 'settings_screen.dart';

/// ----- helper types passed into compute (must be top-level) -----
class _GoogleParseArg {
  final String body;
  _GoogleParseArg(this.body);
}

class _PickBestArg {
  final String src;
  final String? a;
  final String? b;
  final String? c;
  final String toCode;
  _PickBestArg(this.src, this.a, this.b, this.c, this.toCode);
}

/// parse Google translate response body in isolate (compute)
String _parseGoogleResponse(_GoogleParseArg arg) {
  try {
    final data = json.decode(arg.body);
    if (data is List && data.isNotEmpty && data[0] is List) {
      final buffer = StringBuffer();
      for (var seg in data[0]) {
        if (seg is List && seg.isNotEmpty) buffer.write(seg[0]);
      }
      final result = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      return result;
    }
  } catch (_) {}
  return "";
}

/// pick best result in isolate (compute)
String? _pickBestInIsolate(_PickBestArg arg) {
  final srcLower = arg.src.toLowerCase();
  final results =
      [arg.a, arg.b, arg.c].where((x) => x != null && x.isNotEmpty).toList();
  if (results.isEmpty) return null;
  results.removeWhere((x) => x!.toLowerCase() == srcLower);
  if (results.isEmpty) return null;
  results.sort((x, y) => y!.length.compareTo(x!.length));
  // heuristic for Indic scripts
  for (var r in results) {
    final s = r!;
    final looksLikeIndic = RegExp(r'[\u0900-\u0DFF]').hasMatch(s);
    if (looksLikeIndic && arg.toCode != 'en') return s;
  }
  return results.first;
}

/// -------------------- ML Kit language mappers --------------------
TranslateLanguage? _toMlkitLangEnum(String langTag) {
  final code = langTag.split('-').first;
  switch (code) {
    case 'en':
      return TranslateLanguage.english;
    case 'hi':
      return TranslateLanguage.hindi;
    case 'mr':
      return TranslateLanguage.marathi;
    default:
      return null;
  }
}

/// -------------------- Model manager --------------------
final OnDeviceTranslatorModelManager _modelManager =
    OnDeviceTranslatorModelManager();

Future<bool> isModelDownloadedFor(String langTag) async {
  final enumLang = _toMlkitLangEnum(langTag);
  if (enumLang == null) return false;
  final bcp = enumLang.bcpCode;
  try {
    return await _modelManager.isModelDownloaded(bcp);
  } catch (e) {
    debugPrint('isModelDownloadedFor error: $e');
    return false;
  }
}

/// Download with gentle polling (non-blocking)
Future<bool> downloadModelFor(String langTag,
    {Duration timeout = const Duration(seconds: 90)}) async {
  final enumLang = _toMlkitLangEnum(langTag);
  if (enumLang == null) return false;
  final bcp = enumLang.bcpCode;
  try {
    await _modelManager.downloadModel(bcp);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final done = await _modelManager.isModelDownloaded(bcp);
      if (done) return true;
      await Future.delayed(const Duration(seconds: 3));
    }
    return false;
  } catch (e) {
    debugPrint('downloadModelFor error: $e');
    return false;
  }
}

Future<bool> deleteModelFor(String langTag) async {
  final enumLang = _toMlkitLangEnum(langTag);
  if (enumLang == null) return false;
  final bcp = enumLang.bcpCode;
  try {
    await _modelManager.deleteModel(bcp);
    final still = await _modelManager.isModelDownloaded(bcp);
    return !still;
  } catch (e) {
    debugPrint('deleteModelFor error: $e');
    return false;
  }
}

/// -------------------- Connectivity helper --------------------
Future<bool> isOnline() async {
  final conn = await Connectivity().checkConnectivity();
  return conn != ConnectivityResult.none;
}

/// -------------------- Main --------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Hive.initFlutter();
  await Hive.openBox('translations');
  await Hive.openBox('history');
  await Hive.openBox('settings'); // for theme & other app settings
  runApp(const MyApp());
}

/// ===================== APP ROOT =====================
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isDark = false;

  @override
  void initState() {
    super.initState();
    final settings = Hive.box('settings');
    _isDark = settings.get('isDarkTheme', defaultValue: false);
  }

  void _updateTheme(bool value) {
    setState(() => _isDark = value);
    final settings = Hive.box('settings');
    settings.put('isDarkTheme', value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Voice Translator",
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.deepPurple,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
      ),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/home': (context) => VoiceTranslator(onThemeChange: _updateTheme),
        '/login': (context) => const LoginScreen(),
      },
    );
  }
}

/// ===================== SPLASH SCREEN =====================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Slightly longer animation for a smoother reveal
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
    // Keep splash for a bit longer but not too long (1.8 seconds)
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ScaleTransition(
          scale: _scale,
          child: Image.asset('assets/images/voice_translator.png', width: 220),
        ),
      ),
    );
  }
}

/// ===================== MAIN SCREEN =====================
/// Note: WidgetsBindingObserver is mixed in to handle lifecycle (stop audio/TTS when backgrounded)
class VoiceTranslator extends StatefulWidget {
  const VoiceTranslator({super.key, this.onThemeChange});

  final ValueChanged<bool>? onThemeChange;

  @override
  State<VoiceTranslator> createState() => _VoiceTranslatorState();
}

class _VoiceTranslatorState extends State<VoiceTranslator>
    with WidgetsBindingObserver {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  final TextEditingController _textController = TextEditingController();

  String _recognizedText = "";
  String _translatedText = "";
  bool _isListening = false;
  bool _isTranslating = false;
  String? _errorMessage;
  double _ttsVolume = 0.7;

  String _fromLang = "en-US";
  String _toLang = "hi-IN";

  // languages presented in dropdown (UI). Offline supported by MLKit limited to en, hi, mr.
  final Map<String, String> languages = {
    "Assamese": "as-IN",
    "Bengali": "bn-IN",
    "Bhili": "bhb-IN",
    "Bodo": "brx-IN",
    "Dogri": "doi-IN",
    "English": "en-US",
    "Gujarati": "gu-IN",
    "Hindi": "hi-IN",
    "Kannada": "kn-IN",
    "Kashmiri": "ks-IN",
    "Konkani": "kok-IN",
    "Maithili": "mai-IN",
    "Malayalam": "ml-IN",
    "Manipuri": "mni-IN",
    "Marathi": "mr-IN",
    "Nepali": "ne-IN",
    "Oriya": "or-IN",
    "Punjabi": "pa-IN",
    "Rajasthani": "raj-IN",
    "Sanskrit": "sa-IN",
    "Santhali": "sat-IN",
    "Sindhi": "sd-IN",
    "Tamil": "ta-IN",
    "Telugu": "te-IN",
    "Tulu": "tcy-IN",
  };

  bool _isDownloadingModel = false;

  bool get _isDarkTheme => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Load TTS volume from settings
    final settings = Hive.box('settings');
    _ttsVolume = (settings.get('ttsVolume', defaultValue: 0.7) as num).toDouble();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speech.stop();
    _flutterTts.stop();
    _textController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app is backgrounded or detached, ensure audio components are stopped to avoid glitches.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _speech.stop();
      _flutterTts.stop();
      if (mounted) {
        setState(() {
          _isListening = false;
          _isTranslating = false;
        });
      }
    }
  }

  String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _decodeHtmlEntities(String input) {
    if (input.isEmpty) return input;
    return input
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }

  bool _looksLikeLanguageScript(String text, String langCode) {
    if (text.isEmpty) return false;
    final s = text.trim();
    switch (langCode) {
      case 'hi':
      case 'mr':
      case 'ne':
      case 'mai':
      case 'sa':
        return RegExp(r'[\u0900-\u097F]').hasMatch(s);
      case 'bn':
        return RegExp(r'[\u0980-\u09FF]').hasMatch(s);
      case 'gu':
        return RegExp(r'[\u0A80-\u0AFF]').hasMatch(s);
      case 'pa':
        return RegExp(r'[\u0A00-\u0A7F]').hasMatch(s);
      case 'ta':
        return RegExp(r'[\u0B80-\u0BFF]').hasMatch(s);
      case 'te':
        return RegExp(r'[\u0C00-\u0C7F]').hasMatch(s);
      case 'kn':
        return RegExp(r'[\u0C80-\u0CFF]').hasMatch(s);
      case 'ml':
        return RegExp(r'[\u0D00-\u0D7F]').hasMatch(s);
      case 'or':
        return RegExp(r'[\u0B00-\u0B7F]').hasMatch(s);
      default:
        return RegExp(r'[A-Za-z]').hasMatch(s);
    }
  }

  // ---------------- HISTORY ----------------

  /// Save a translation to per-user history (avoids duplicates by moving existing to top)
  Future<void> _addToHistory(String fromLangTag, String toLangTag, String src,
      String translated) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final box = Hive.box('history');

    final uid = user.uid;
    final List<dynamic> list = List<dynamic>.from(box.get(uid) ?? <dynamic>[]);

    // canonicalize key to avoid duplicates
    final key = '${fromLangTag}_${toLangTag}_${_normalize(src).toLowerCase()}';

    // remove previous occurrences
    list.removeWhere((item) {
      try {
        final existingKey =
            '${item['from']}_${item['to']}_${_normalize(item['src']).toLowerCase()}';
        return existingKey == key;
      } catch (_) {
        return false;
      }
    });

    // insert at beginning
    list.insert(0, {
      'from': fromLangTag,
      'to': toLangTag,
      'src': src,
      'translated': translated,
      'ts': DateTime.now().toIso8601String(),
    });

    // keep history reasonable length (optional) - keep latest 200
    if (list.length > 200) list.removeRange(200, list.length);

    await box.put(uid, list);
  }

  // ---------------- TRANSLATION LOGIC ----------------

  Future<String?> _translateText(String text, String from, String to) async {
    final src = _normalize(text);
    if (src.isEmpty) return null;

    final fromCode = from.split('-').first; // e.g. 'en'
    final toCode = to.split('-').first; // e.g. 'hi'

    // cache lookup
    final cache = Hive.box('translations');
    final cacheKey = '${fromCode}_${toCode}_${src.toLowerCase()}';
    if (cache.containsKey(cacheKey)) {
      return cache.get(cacheKey) as String;
    }

    // Determine MLKit support for these languages
    final fromEnum = _toMlkitLangEnum(from);
    final toEnum = _toMlkitLangEnum(to);
    final toBcp = toEnum?.bcpCode;

    // If both languages are supported on-device, attempt on-device translation first.
    if (fromEnum != null && toEnum != null && toBcp != null) {
      try {
        final isDownloaded = await _modelManager.isModelDownloaded(toBcp);
        if (isDownloaded) {
          try {
            final translator = OnDeviceTranslator(
                sourceLanguage: fromEnum, targetLanguage: toEnum);
            final translated = await translator.translateText(src);
            await translator.close();

            final finalTranslated = translated.trim();
            if (finalTranslated.isNotEmpty) {
              cache.put(cacheKey, finalTranslated);
              return finalTranslated;
            }
          } catch (e) {
            debugPrint("On-device translator runtime error: $e");
            // fall through to online fallback below
          }
        } else {
          // model not downloaded: try online fallback below (don't return early)
          debugPrint(
              "On-device model for $toBcp not downloaded. Will attempt online fallback if internet is available.");
        }
      } catch (e) {
        debugPrint("isModelDownloaded check error: $e");
        // fall through to online fallback
      }
    } else {
      debugPrint(
          "ML Kit does not support on-device translation for $fromCode -> $toCode");
    }

    // If we're here, either on-device wasn't available or it failed — try online if we have internet.
    if (await isOnline()) {
      final online = await _translateOnline(src, fromCode, toCode);
      if (online.isNotEmpty && online != "Translation failed") {
        cache.put(cacheKey, online);
        return online;
      } else {
        // online attempt failed; fall through to return a user-facing message
        debugPrint(
            "Online translation attempts failed for '$src' ($fromCode->$toCode)");
        return "Translation failed (online).";
      }
    }

    // No offline model available and no internet
    return "No internet connection and offline model not available.\nPlease connect to the internet or download the offline model.";
  }

  Future<String> _translateOnline(
      String src, String fromCode, String toCode) async {
    String? googleResult;
    String? libreResult;
    String? memoryResult;

    // 1) Google (unofficial API) - parse in isolate
    try {
      final uri = Uri.parse(
          'https://translate.googleapis.com/translate_a/single?client=gtx&sl=$fromCode&tl=$toCode&dt=t&q=${Uri.encodeComponent(src)}');
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        googleResult =
            await compute(_parseGoogleResponse, _GoogleParseArg(res.body));
      }
    } catch (e) {
      debugPrint("Google Translate error: $e");
    }

    // 2) LibreTranslate fallback
    try {
      final res = await http
          .post(
            Uri.parse("https://libretranslate.de/translate"),
            headers: {"Content-Type": "application/json"},
            body: json.encode({
              "q": src,
              "source": fromCode,
              "target": toCode,
              "format": "text",
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        libreResult = _decodeHtmlEntities(data["translatedText"].toString());
      }
    } catch (e) {
      debugPrint("LibreTranslate error: $e");
    }

    // 3) MyMemory fallback
    try {
      final url =
          "https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(src)}&langpair=${fromCode}|${toCode}";
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        memoryResult = _decodeHtmlEntities(
            data["responseData"]["translatedText"].toString());
      }
    } catch (e) {
      debugPrint("MyMemory error: $e");
    }

    // Choose best result in isolate
    final pick = await compute(
      _pickBestInIsolate,
      _PickBestArg(src, googleResult, libreResult, memoryResult, toCode),
    );

    return pick ??
        googleResult ??
        libreResult ??
        memoryResult ??
        "Translation failed";
  }

  // ---------------- LISTEN & TRANSLATE ----------------

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;
    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  Future<void> _startListening() async {
    FocusScope.of(context).unfocus();
    if (_fromLang == _toLang) {
      if (mounted) {
        setState(() => _errorMessage = "⚠️ Please choose different languages.");
      }
      return;
    }

    // request permission
    if (!await _ensureMicPermission()) {
      if (mounted) {
        setState(() => _errorMessage = "Microphone permission required.");
      }
      return;
    }

    bool available = await _speech.initialize();
    if (!available) {
      if (mounted) setState(() => _errorMessage = "Microphone not available.");
      return;
    }

    if (mounted) {
      setState(() {
        _isListening = true;
        _recognizedText = "";
        _translatedText = "";
        _errorMessage = null;
      });
    }

    _speech.listen(
      localeId: _fromLang,
      onResult: (val) async {
        if (val.finalResult && val.recognizedWords.isNotEmpty) {
          if (mounted) setState(() => _recognizedText = val.recognizedWords);
          await _handleTranslation(val.recognizedWords);
        }
      },
      cancelOnError: true,
    );
  }

  void _stopListening() {
    _speech.stop();
    if (mounted) setState(() => _isListening = false);
  }

  Future<void> _handleTranslation(String text) async {
    if (mounted) {
      setState(() {
        _isTranslating = true;
        _errorMessage = null;
      });
    }

    final translated =
        await _translateText(text, _fromLang, _toLang) ?? "Translation failed";

    if (mounted) {
      setState(() {
        _translatedText = translated;
        _isTranslating = false;
      });
    }

    // Save to user's history (if logged in). Fire-and-forget, we don't await here so UI isn't blocked.
    _addToHistory(_fromLang, _toLang, text, translated);

    try {
      await _flutterTts.setLanguage(_toLang);
      await _flutterTts.setVolume(_ttsVolume);
      await _flutterTts.speak(translated);
    } catch (e) {
      debugPrint("TTS error: $e");
    }
  }

  Future<void> _repeatTranslation() async {
    if (_translatedText.isEmpty) return;
    await _flutterTts.setLanguage(_toLang);
    await _flutterTts.speak(_translatedText);
  }

  Future<void> _onDownloadModelPressed() async {
    final targetLang = _toLang;
    final enumLang = _toMlkitLangEnum(targetLang);
    if (enumLang == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Offline model not available for this language')));
      }
      return;
    }
    if (_isDownloadingModel) return;
    if (mounted) setState(() => _isDownloadingModel = true);
    final success = await downloadModelFor(targetLang,
        timeout: const Duration(seconds: 90));
    if (mounted) {
      setState(() => _isDownloadingModel = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(success
              ? 'Model downloaded'
              : 'Model download failed or timed out')));
    }
  }

  Future<void> _onDeleteModelPressed() async {
    final targetLang = _toLang;
    final enumLang = _toMlkitLangEnum(targetLang);
    if (enumLang == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No offline model for this language')));
      }
      return;
    }
    final ok = await deleteModelFor(targetLang);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'Model deleted' : 'Failed to delete model')));
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title:
            const Text("Speakeasy", style: TextStyle(color: Colors.deepPurple)),
        actions: [
          Builder(builder: (context) {
            final user = FirebaseAuth.instance.currentUser;
            // Logged-in state
            if (user != null) {
              return Row(children: [
                if (user.photoURL != null)
                  CircleAvatar(
                      radius: 16,
                      backgroundImage: NetworkImage(user.photoURL!)),
                const SizedBox(width: 8),
                Text(user.displayName ?? user.email ?? "User",
                    style: const TextStyle(color: Colors.deepPurple)),
                const SizedBox(width: 12),

                // HISTORY ICON - opens HistoryScreen and returns selected item
                IconButton(
                  tooltip: "History",
                  icon: const Icon(Icons.history, color: Colors.deepPurple),
                  onPressed: () async {
                    final result =
                        await Navigator.of(context).push<Map<String, dynamic>>(
                      MaterialPageRoute(builder: (_) => const HistoryScreen()),
                    );
                    if (result != null) {
                      final src = result['src'] as String? ?? '';
                      final from = result['from'] as String? ?? _fromLang;
                      final to = result['to'] as String? ?? _toLang;
                      setState(() {
                        _fromLang = from;
                        _toLang = to;
                        _textController.text = src;
                        _recognizedText = src;
                      });
                      // re-run translation for the selected item
                      _handleTranslation(src);
                    }
                  },
                ),

                // SETTINGS ICON
                IconButton(
                  tooltip: "Settings",
                  icon: const Icon(Icons.settings, color: Colors.deepPurple),
                  onPressed: () async {
                    final value = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                          builder: (_) => const SettingsScreen()),
                    );
                    if (value != null && widget.onThemeChange != null) {
                      widget.onThemeChange!(value);
                    }
                  },
                ),

                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.deepPurple),
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Logged out")));
                      setState(() {});
                    }
                  },
                )
              ]);
            }

            // Not logged-in: show Settings + Login
            return Row(
              children: [
                IconButton(
                  tooltip: "Settings",
                  icon: const Icon(Icons.settings, color: Colors.deepPurple),
                  onPressed: () async {
                    final value = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                          builder: (_) => const SettingsScreen()),
                    );
                    if (value != null && widget.onThemeChange != null) {
                      widget.onThemeChange!(value);
                    }
                  },
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pushNamed(context, '/login').then((_) {
                      if (mounted) setState(() {});
                    });
                  },
                  icon: const Icon(Icons.login, color: Colors.deepPurple),
                  label: const Text("Login",
                      style: TextStyle(color: Colors.deepPurple)),
                ),
              ],
            );
          })
        ],
        iconTheme: const IconThemeData(color: Colors.deepPurple),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text("🎙️ Voice Translator",
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple)),
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: _isListening ? _stopListening : _startListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 110,
                  width: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                        colors: _isListening
                            ? [Colors.redAccent, Colors.pink]
                            : [Colors.deepPurple, Colors.blueAccent]),
                    boxShadow: [
                      BoxShadow(
                          color: (_isListening
                                  ? Colors.redAccent
                                  : Colors.deepPurple)
                              .withOpacity(0.3),
                          blurRadius: 18,
                          spreadRadius: 4)
                    ],
                  ),
                  child: Icon(_isListening ? Icons.stop : Icons.mic,
                      size: 48, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                  child: _buildDropdown("From", _fromLang, Colors.blueAccent,
                      (v) => setState(() => _fromLang = v!))),
              const SizedBox(width: 10),
              Expanded(
                  child: _buildDropdown("To", _toLang, Colors.orangeAccent,
                      (v) => setState(() => _toLang = v!))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      _isDownloadingModel ? null : _onDownloadModelPressed,
                  child: _isDownloadingModel
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("Download Offline Model"),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _onDeleteModelPressed,
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                child: const Text("Delete Offline Model"),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    hintText: "Type or speak something...",
                    hintStyle: TextStyle(
                      color: _isDarkTheme ? Colors.white60 : Colors.black45,
                    ),
                    filled: true,
                    fillColor:
                        _isDarkTheme ? Colors.white10 : Colors.grey.shade100,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                  minLines: 1,
                  maxLines: 3,
                  style: TextStyle(
                    color: _isDarkTheme ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                  icon: const Icon(Icons.send,
                      color: Colors.deepPurple, size: 28),
                  onPressed: () {
                    final txt = _textController.text.trim();
                    if (txt.isNotEmpty) _handleTranslation(txt);
                  }),
            ]),
            const SizedBox(height: 16),
            _buildTextBox(
                Icons.record_voice_over,
                Colors.blueAccent,
                "Recognized Text",
                _recognizedText.isEmpty ? "—" : _recognizedText),
            const SizedBox(height: 12),
            _buildTextBox(
                Icons.translate,
                Colors.green,
                "Translation",
                _errorMessage ??
                    (_translatedText.isEmpty ? "—" : _translatedText)),
            const SizedBox(height: 10),
            if (_translatedText.isNotEmpty)
              Center(
                  child: ElevatedButton.icon(
                      onPressed: _repeatTranslation,
                      icon: const Icon(Icons.volume_up),
                      label: const Text("Listen Again"),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20))))),
            if (_isTranslating)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: CircularProgressIndicator())),
            const SizedBox(height: 24),
            _buildModelStatusRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildModelStatusRow() {
    // show a simple status for selected target language: downloaded or not
    return FutureBuilder<bool>(
      future: isModelDownloadedFor(_toLang),
      builder: (context, snap) {
        final downloaded = snap.data ?? false;
        return Row(
          children: [
            const Icon(Icons.storage),
            const SizedBox(width: 8),
            Text(
                "Offline model for ${_toLang.split('-').first.toUpperCase()}: ${downloaded ? 'Downloaded' : 'Not downloaded'}"),
            const SizedBox(width: 12),
            TextButton(
                onPressed: () async {
                  final ok = await isModelDownloadedFor(_toLang);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text(ok ? 'Model present' : 'Model not present')));
                  }
                },
                child: const Text("Check")),
          ],
        );
      },
    );
  }

  Widget _buildDropdown(String label, String value, Color color,
      ValueChanged<String?> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10)),
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          underline: const SizedBox(),
          dropdownColor: Colors.white,
          items: languages.entries
              .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
              .toList(),
          onChanged: onChanged,
        ),
      )
    ]);
  }

  Widget _buildTextBox(IconData icon, Color color, String label, String value) {
    final boxColor =
        _isDarkTheme ? Colors.white.withOpacity(0.12) : color.withOpacity(0.08);
    final textColor = _isDarkTheme ? Colors.white : Colors.black87;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: boxColor, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: color, fontSize: 16))
        ]),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(fontSize: 16, color: textColor)),
      ]),
    );
  }
}
