class FileItem {
  final String id;
  final String name;
  final String path; // локальный путь

  FileItem({required this.id, required this.name, required this.path});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'path': path};

  factory FileItem.fromJson(Map<String, dynamic> j) =>
      FileItem(id: j['id'], name: j['name'], path: j['path']);
}
