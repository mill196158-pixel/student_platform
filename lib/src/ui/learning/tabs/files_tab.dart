import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../models/file_item.dart';
import '../state/team_cubit.dart';
import 'assignments/assignments_tab.dart';


class FilesTab extends StatelessWidget {
  const FilesTab({super.key});

  Future<void> _pickAndSave(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (res == null || res.files.single.path == null) return;
    final source = File(res.files.single.path!);

    final dir = await getApplicationDocumentsDirectory();
    final destPath = '${dir.path}/${res.files.single.name}';
    await source.copy(destPath);

    final state = context.read<TeamCubit>().state;
    final list = [...state.files, FileItem(id: DateTime.now().millisecondsSinceEpoch.toString(), name: res.files.single.name, path: destPath)];
    await context.read<TeamCubit>().setFiles(list);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TeamCubit, TeamState>(
      builder: (context, state) {
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _pickAndSave(context),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Загрузить файл'),
                    ),
                    const SizedBox(width: 12),
                    Text('Файлы хранятся локально', style: TextStyle(color: Colors.grey.shade400)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: state.files.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final f = state.files[i];
                  return ListTile(
                    onTap: () => OpenFilex.open(f.path),
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        final list = [...state.files]..removeAt(i);
                        context.read<TeamCubit>().setFiles(list);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
