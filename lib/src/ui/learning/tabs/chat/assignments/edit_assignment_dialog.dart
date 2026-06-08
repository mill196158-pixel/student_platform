import 'package:flutter/material.dart';

import '../../../models/assignment.dart';
import 'assignment_form_dialog.dart';

Future<(String, String, String?, String?, List<Map<String, String>>)?> showEditAssignmentDialog(
  BuildContext context,
  Assignment a,
) => showAssignmentFormDialog(context, initial: a);
