/// Isolated diagnostic build: suppresses enumerated automatic server mutations.
/// This is not a general guarantee that SDKs or other processes cannot write.
const bool qaNoAutomaticWrites = bool.fromEnvironment('QA_NO_AUTOMATIC_WRITES');
