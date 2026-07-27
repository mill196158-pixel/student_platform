enum TeacherStatus { draft, published, archived }

class TeacherItem {
  const TeacherItem({
    required this.id,
    required this.fullName,
    this.department,
    this.position,
    this.academicDegree,
    this.aboutText = '',
    this.status = TeacherStatus.draft,
    this.contactsPublic = const {},
    this.relatedSubjects = const [],
    this.photoPath,
    this.photoPlaceholder = true,
  });

  final String id;
  final String fullName;
  final String? department;
  final String? position;
  final String? academicDegree;
  final String aboutText;
  final TeacherStatus status;
  final Map<String, dynamic> contactsPublic;
  final List<String> relatedSubjects;
  final String? photoPath;
  final bool photoPlaceholder;

  factory TeacherItem.fromJson(Map<String, dynamic> json) => TeacherItem(
    id: '${json['id'] ?? ''}',
    fullName: '${json['full_name'] ?? ''}',
    department: json['department']?.toString(),
    position: json['position']?.toString(),
    academicDegree: json['academic_degree']?.toString(),
    aboutText: '${json['about_text'] ?? ''}',
    status: TeacherStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => TeacherStatus.draft,
    ),
    contactsPublic: json['contacts_public'] is Map
        ? Map<String, dynamic>.from(json['contacts_public'] as Map)
        : const {},
    relatedSubjects: [
      for (final item in (json['related_subjects'] as List? ?? const []))
        if (item is Map &&
            (item['canonical_name']?.toString().isNotEmpty ?? false))
          item['canonical_name'].toString()
        else if (item != null)
          item.toString(),
    ],
    photoPath: json['photo_path']?.toString(),
    photoPlaceholder:
        json['photo_placeholder'] == true || json['photo_path'] == null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'full_name': fullName,
    'department': department,
    'position': position,
    'academic_degree': academicDegree,
    'about_text': aboutText,
    'status': status.name,
    'contacts_public': contactsPublic,
    'related_subjects': relatedSubjects,
    'photo_path': photoPath,
    'photo_placeholder': photoPlaceholder,
  };

  TeacherItem copyWith({
    String? fullName,
    String? department,
    String? position,
    String? academicDegree,
    String? aboutText,
    TeacherStatus? status,
    Map<String, dynamic>? contactsPublic,
    List<String>? relatedSubjects,
    String? photoPath,
    bool? photoPlaceholder,
  }) => TeacherItem(
    id: id,
    fullName: fullName ?? this.fullName,
    department: department ?? this.department,
    position: position ?? this.position,
    academicDegree: academicDegree ?? this.academicDegree,
    aboutText: aboutText ?? this.aboutText,
    status: status ?? this.status,
    contactsPublic: contactsPublic ?? this.contactsPublic,
    relatedSubjects: relatedSubjects ?? this.relatedSubjects,
    photoPath: photoPath ?? this.photoPath,
    photoPlaceholder: photoPlaceholder ?? this.photoPlaceholder,
  );
}
