/// Converts a student login or email into the email used by Supabase Auth.
///
/// Students type only their record book number, but Auth users are created with
/// a technical email: `<login>@student.local`.
String normalizeLoginToAuthEmail(String input) {
  final value = input.trim().toLowerCase();

  if (value.contains('@')) {
    return value;
  }

  return '$value@student.local';
}

String toAuthEmail(String input) => normalizeLoginToAuthEmail(input);
