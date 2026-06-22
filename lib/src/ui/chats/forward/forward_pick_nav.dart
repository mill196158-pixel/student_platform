import 'package:flutter/material.dart';
import '../forward/forward_picker.dart' show ForwardTarget;
import '../my_chats_screen.dart';

Future<ForwardTarget?> pickForwardTarget(BuildContext context) async {
  return await Navigator.of(context).push<ForwardTarget>(
    MaterialPageRoute(builder: (_) => const MyChatsScreen(pickMode: true)),
  );
}
