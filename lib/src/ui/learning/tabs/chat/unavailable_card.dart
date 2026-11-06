import 'package:flutter/widgets.dart';
import 'card_visibility_scope.dart';

/// Do not display unavailable card rows; report to the list so it can also
/// omit a date header that would otherwise have no visible content.
class UnavailableChatCard extends StatelessWidget {
  const UnavailableChatCard({super.key});

  @override
  Widget build(BuildContext context) {
    ChatCardVisibilityScope.setVisible(context, false);
    return const SizedBox.shrink();
  }
}
