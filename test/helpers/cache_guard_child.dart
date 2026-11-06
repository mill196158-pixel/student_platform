import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final file = File(arguments[0]);
  final token = arguments[1];
  await file.create(exclusive: true);
  final handle = await file.open(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  await handle.writeString(token);
  await handle.flush();
  stdout.writeln('ready');
  await stdin.transform(utf8.decoder).first;
  await handle.unlock();
  await handle.close();
}
