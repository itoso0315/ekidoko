/// Easy uses selected major stations; both modes share maps, hints and scores.
enum GameDifficulty {
  easy('Easy'),
  hard('Hard');

  const GameDifficulty(this.label);
  final String label;
}
