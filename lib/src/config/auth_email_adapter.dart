/// Превращает введённый логин в email для Supabase Auth.
/// Если уже есть '@' — возвращает как есть.
String toAuthEmail(String input) {
  final s = input.trim();
  if (s.contains('@')) return s;
  return '$s@app.local';
}
