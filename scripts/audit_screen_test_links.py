"""Report direct test references; deliberately NOT a coverage percentage."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
tests = list((ROOT / 'test').rglob('*_test.dart'))
rows = []
for source in sorted((ROOT / 'lib').rglob('*.dart')):
    text = source.read_text(encoding='utf-8')
    classes = re.findall(r'class\s+(\w*(?:Screen|Tab))\b', text)
    if not classes:
        continue
    uri = 'package:student_platform/' + source.relative_to(ROOT / 'lib').as_posix()
    linked = [p.relative_to(ROOT).as_posix() for p in tests
              if uri in p.read_text(encoding='utf-8')]
    rows.append(f"| {source.relative_to(ROOT).as_posix()} | "
                f"{', '.join(linked) if linked else 'Нет прямого импорта'} |")
output = ROOT / 'docs' / 'SCREEN_TEST_LINKS_2026_10_29.md'
output.write_text(
    '# Связи экранов с существующими тестами\n\n'
    'Автоматическая статическая карта прямых импортов. Импорт не доказывает, '
    'что весь экран проверен: тест может проверять только вспомогательный виджет. '
    'Отсутствие импорта не исключает косвенное покрытие. '
    'Это НЕ E2E-покрытие и НЕ процент протестированного функционала.\n\n'
    '| Исходник | Тесты с прямым импортом |\n|---|---|\n' + '\n'.join(rows) + '\n',
    encoding='utf-8')
print(f'{len(rows)} source files mapped to {len(tests)} test files: {output}')
