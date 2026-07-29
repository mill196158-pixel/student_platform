/// Generation-token helper for hero image loads (Stage 16.2 P1).
/// Stale async completions must not overwrite a newer card's hero.
bool subjectHeroLoadIsCurrent({
  required int startedGeneration,
  required int currentGeneration,
}) =>
    startedGeneration == currentGeneration;
