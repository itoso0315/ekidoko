import 'package:flutter/material.dart';
import 'screens/app_screen.dart';
import 'game/game.dart';
import 'package:flutter/services.dart';

void main() => runApp(const EkidokoApp());

const accent = Color(0xff187864);
const ink = Color(0xff203b33);

class EkidokoApp extends StatelessWidget {
  const EkidokoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ekidoko',
    debugShowCheckedModeBanner: false,
    theme: buildEkidokoTheme(),
    home: const CatalogScreen(),
  );
}

/// Retryable startup gate: malformed catalog data never enters a game.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, this.loader = loadStationCatalog});
  final Future<StationCatalog> Function() loader;
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

Future<StationCatalog> loadStationCatalog() async {
  final catalog = StationCatalog.parse(
    await rootBundle.loadString('assets/data/stations.json'),
  );
  if (catalog.select().length < 10) {
    throw const StationDataException(['出題可能な駅が10駅以上必要です。enabledを確認してください。']);
  }
  return catalog;
}

class _CatalogScreenState extends State<CatalogScreen> {
  Game? _game;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final catalog = await widget.loader();
      if (!mounted) return;
      setState(() => _game = Game(catalog: catalog));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _game?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_game != null) return AppScreen(game: _game!);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: _error == null
                ? const CircularProgressIndicator()
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          color: accent,
                          size: 32,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '駅データを読み込めませんでした',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(_error.toString()),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('再読み込み'),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

ThemeData buildEkidokoTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: const Color(0xfff8faf7),
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent,
    primary: accent,
    surface: const Color(0xfff8faf7),
  ),
  textTheme: ThemeData.light().textTheme.apply(
    bodyColor: ink,
    displayColor: ink,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(double.infinity, 54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xffdfe6df)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xffdfe6df)),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  ),
);
