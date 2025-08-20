import 'package:flutter/foundation.dart';

/// Единая точка правды для режима отображения заданий.
/// false = список, true = сетка
class AssignmentsViewMode {
  static final ValueNotifier<bool> grid = ValueNotifier<bool>(false);
}
