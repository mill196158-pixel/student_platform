enum SubjectStatus { draft, published, archived }

class SubjectItem {
  const SubjectItem({
    required this.id,
    required this.canonicalName,
    this.description = '',
    this.department,
    this.controlForm,
    this.difficultyLabel,
    this.requirements = '',
    this.learningOutcomes = '',
    this.shortDescription = '',
    this.whatToExpect = '',
    this.howToPass = '',
    this.usefulMaterialsNote = '',
    this.commonPitfalls = '',
    this.status = SubjectStatus.draft,
    this.relatedTeachers = const [],
    this.usefulLinks = const [],
  });

  final String id;
  final String canonicalName;
  final String description;
  final String? department;
  final String? controlForm;
  final String? difficultyLabel;
  final String requirements;
  final String learningOutcomes;
  final String shortDescription;
  final String whatToExpect;
  final String howToPass;
  final String usefulMaterialsNote;
  final String commonPitfalls;
  final SubjectStatus status;
  final List<String> relatedTeachers;
  final List<dynamic> usefulLinks;

  factory SubjectItem.fromJson(Map<String, dynamic> json) => SubjectItem(
    id: '${json['id'] ?? ''}',
    canonicalName: '${json['canonical_name'] ?? ''}',
    description: '${json['description'] ?? ''}',
    department: json['department']?.toString(),
    controlForm: json['control_form']?.toString(),
    difficultyLabel: json['difficulty_label']?.toString(),
    requirements: '${json['requirements'] ?? ''}',
    learningOutcomes: '${json['learning_outcomes'] ?? ''}',
    shortDescription: '${json['short_description'] ?? ''}',
    whatToExpect: '${json['what_to_expect'] ?? ''}',
    howToPass: '${json['how_to_pass'] ?? ''}',
    usefulMaterialsNote: '${json['useful_materials_note'] ?? ''}',
    commonPitfalls: '${json['common_pitfalls'] ?? ''}',
    status: SubjectStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => SubjectStatus.draft,
    ),
    relatedTeachers: [
      for (final item in (json['related_teachers'] as List? ?? const []))
        if (item is Map && (item['full_name']?.toString().isNotEmpty ?? false))
          item['full_name'].toString()
        else if (item != null)
          item.toString(),
    ],
    usefulLinks: List<dynamic>.from(json['useful_links'] as List? ?? const []),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'canonical_name': canonicalName,
    'description': description,
    'department': department,
    'control_form': controlForm,
    'difficulty_label': difficultyLabel,
    'requirements': requirements,
    'learning_outcomes': learningOutcomes,
    'short_description': shortDescription,
    'what_to_expect': whatToExpect,
    'how_to_pass': howToPass,
    'useful_materials_note': usefulMaterialsNote,
    'common_pitfalls': commonPitfalls,
    'status': status.name,
    'useful_links': usefulLinks,
  };

  SubjectItem copyWith({
    String? canonicalName,
    String? description,
    String? department,
    String? controlForm,
    String? difficultyLabel,
    String? requirements,
    String? learningOutcomes,
    String? shortDescription,
    String? whatToExpect,
    String? howToPass,
    String? usefulMaterialsNote,
    String? commonPitfalls,
    SubjectStatus? status,
  }) => SubjectItem(
    id: id,
    canonicalName: canonicalName ?? this.canonicalName,
    description: description ?? this.description,
    department: department ?? this.department,
    controlForm: controlForm ?? this.controlForm,
    difficultyLabel: difficultyLabel ?? this.difficultyLabel,
    requirements: requirements ?? this.requirements,
    learningOutcomes: learningOutcomes ?? this.learningOutcomes,
    shortDescription: shortDescription ?? this.shortDescription,
    whatToExpect: whatToExpect ?? this.whatToExpect,
    howToPass: howToPass ?? this.howToPass,
    usefulMaterialsNote: usefulMaterialsNote ?? this.usefulMaterialsNote,
    commonPitfalls: commonPitfalls ?? this.commonPitfalls,
    status: status ?? this.status,
    relatedTeachers: relatedTeachers,
    usefulLinks: usefulLinks,
  );
}
