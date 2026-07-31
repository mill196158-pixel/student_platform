/// Moscow calendar helpers for schedule/home date filtering.
class MskDate {
  MskDate._();

  static const _mskOffset = Duration(hours: 3);

  static DateTime now() {
    final msk = DateTime.now().toUtc().add(_mskOffset);
    return DateTime(
      msk.year,
      msk.month,
      msk.day,
      msk.hour,
      msk.minute,
      msk.second,
      msk.millisecond,
      msk.microsecond,
    );
  }

  /// Calendar date in Moscow (year/month/day only).
  static DateTime calendarDate(DateTime value) {
    if (!value.isUtc) {
      return DateTime(value.year, value.month, value.day);
    }
    final msk = value.add(_mskOffset);
    return DateTime(msk.year, msk.month, msk.day);
  }

  static DateTime parseDatabaseDate(dynamic value) {
    if (value is DateTime) return calendarDate(value);

    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return today();

    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (dateOnly != null) {
      return DateTime(
        int.parse(dateOnly.group(1)!),
        int.parse(dateOnly.group(2)!),
        int.parse(dateOnly.group(3)!),
      );
    }

    return calendarDate(DateTime.parse(raw));
  }

  static DateTime today() {
    final now = MskDate.now();
    return DateTime(now.year, now.month, now.day);
  }

  static bool isSameCalendarDate(DateTime a, DateTime b) {
    final da = calendarDate(a);
    final db = calendarDate(b);
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }

  static bool isToday(DateTime value) => isSameCalendarDate(value, today());

  static int minutesOfDay(DateTime value) => value.hour * 60 + value.minute;

  static String isoDate(DateTime value) {
    final date = calendarDate(value);
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
