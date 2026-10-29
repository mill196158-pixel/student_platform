"""Static Dart import inventory, including conditional platform imports.

Reachability is evidence for review, never an automatic deletion instruction.
"""
from pathlib import Path
import re
import json

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r'\b(?:import|export|part)\s+([^;]+);', re.S)


def dependencies(file):
    result = []
    for directive in DIRECTIVE.findall(file.read_text(encoding='utf-8')):
        for uri in re.findall(r'''['"]([^'"]+\.dart)['"]''', directive):
            if uri.startswith('package:student_platform/'):
                target = ROOT / 'lib' / uri.split('/', 1)[1]
            elif ':' not in uri:
                target = file.parent / uri
            else:
                continue
            result.append(target.resolve())
    return result


def main():
    files = sorted((ROOT / 'lib').rglob('*.dart'))
    graph = {f.resolve(): dependencies(f) for f in files}
    runtime = set()
    pending = [ROOT / 'lib/main.dart']
    while pending:
        current = pending.pop().resolve()
        if current in runtime:
            continue
        runtime.add(current)
        pending.extend(graph.get(current, []))
    records = []
    for file in files:
        text = file.read_text(encoding='utf-8')
        records.append({
            'path': file.relative_to(ROOT).as_posix(),
            'runtime_reachable': file.resolve() in runtime,
            'lines': len(text.splitlines()),
            'screen_classes': re.findall(r'class\s+(\w*(?:Screen|Tab))\b', text),
            'imports': [p.relative_to(ROOT).as_posix() for p in graph[file.resolve()]
                        if p.is_relative_to(ROOT)],
        })
    (ROOT / 'docs/CODE_REACHABILITY_2026_10_29.json').write_text(
        json.dumps({'note': 'Static runtime graph including conditional imports; external entrypoints require manual review.',
                    'dart_files': len(files), 'files': records}, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# Карта экранов после очистки — 29.10.2026', '',
             'Статическая проверка связей от lib/main.dart, включая условные импорты.',
             'Это не доказательство корректности каждого пользовательского сценария.', '',
             '| Файл | Классы экранов | Строк | Достижим из main |',
             '|---|---|---:|---|']
    for item in records:
        if item['screen_classes']:
            lines.append('| ' + item['path'] + ' | ' + ', '.join(item['screen_classes']) +
                         ' | ' + str(item['lines']) + ' | ' + ('да' if item['runtime_reachable'] else 'нет, требует отдельного решения') + ' |')
    lines += ['', '## Админка', '', 'Статическая инвентаризация страниц Admin; проверка поведения — отдельные тесты.', '',
              '| Файл | Классы страниц | Строк |', '|---|---|---:|']
    for file in sorted((ROOT / 'admin_console/lib').rglob('*.dart')):
        text = file.read_text(encoding='utf-8')
        classes = re.findall(r'class\s+(\w*(?:Screen|Page|View))\b', text)
        classes = [name for name in classes if name not in ('AcademicTextPage', 'AcademicTermView')]
        if classes:
            lines.append('| ' + file.relative_to(ROOT).as_posix() + ' | ' + ', '.join(classes) +
                         ' | ' + str(len(text.splitlines())) + ' |')
    (ROOT / 'docs/SCREEN_INVENTORY_2026_10_29.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('Dart files:', len(files), 'screen files:', sum(bool(r['screen_classes']) for r in records))


if __name__ == '__main__':
    main()
