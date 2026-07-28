import 'package:flutter/material.dart';

class ChatPlusAction {
  final IconData icon;
  final String title;
  final String subtitle;
  final Future<void> Function()? onTap;
  final bool emphasized;
  final bool enabled;
  final bool loading;

  const ChatPlusAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.emphasized = false,
    this.enabled = true,
    this.loading = false,
  });
}

class ChatPlusButton extends StatelessWidget {
  final List<ChatPlusAction> actions;

  const ChatPlusButton({
    super.key,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .78),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.add,
              size: 24, color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              color: colorScheme.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                        child: Text(
                          'Действия в чате',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      for (final action in actions)
                        _PlusActionTile(
                          action: action,
                          onTap: () async {
                            if (!action.enabled || action.loading) return;
                            Navigator.pop(sheetContext);
                            await action.onTap?.call();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlusActionTile extends StatelessWidget {
  final ChatPlusAction action;
  final Future<void> Function() onTap;

  const _PlusActionTile({
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final disabled = !action.enabled || action.loading;
    final bg = action.emphasized
        ? colorScheme.primaryContainer.withValues(alpha: disabled ? .35 : .75)
        : colorScheme.surfaceContainerHighest.withValues(alpha: .7);
    final titleColor = action.emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;
    final subtitleColor = action.emphasized
        ? colorScheme.onPrimaryContainer.withValues(alpha: .75)
        : colorScheme.onSurface.withValues(alpha: 0.55);
    final iconColor = action.emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: disabled ? null : onTap,
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: .5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colorScheme.surface.withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: action.loading
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: iconColor,
                          ),
                        )
                      : Icon(action.icon, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!disabled)
                  Icon(Icons.chevron_right,
                      color: titleColor.withValues(alpha: .55)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
