import 'package:ekidoko/game/highest_rank_store.dart';
import 'package:ekidoko/game/result_rating.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stores and loads the highest rank across games', () async {
    const store = PreferencesHighestRankStore();

    expect(await store.load(), isNull);
    expect(await store.record(ResultRank.a), ResultRank.a);
    expect(await store.record(ResultRank.c), ResultRank.a);
    expect(await store.load(), ResultRank.a);
    expect(await store.record(ResultRank.ss), ResultRank.ss);
    expect(await store.load(), ResultRank.ss);
  });

  test('rejects an invalid saved rank value', () async {
    SharedPreferences.setMockInitialValues({
      'ekidoko.highestRank.minimumPoints': 701,
    });

    expect(
      () => const PreferencesHighestRankStore().load(),
      throwsFormatException,
    );
  });
}
