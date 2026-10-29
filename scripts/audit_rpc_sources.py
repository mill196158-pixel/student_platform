"""Static RPC source inventory; never connects to any database."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
calls = {}
for path in (root/'lib').rglob('*.dart'):
    for name in re.findall(r"\.rpc\(\s*['\"]([a-zA-Z0-9_]+)['\"]", path.read_text('utf-8')):
        calls.setdefault(name,set()).add(path.relative_to(root).as_posix())
definitions = {}
for path in (root/'supabase').rglob('*.sql'):
    for name in re.findall(r'create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?"?([a-zA-Z0-9_]+)',path.read_text('utf-8'),re.I):
        definitions.setdefault(name,set()).add(path.relative_to(root).as_posix())
lines = ['# Серверные функции, вызываемые приложением', '',
         'Статический поиск литералов .rpc в lib и CREATE FUNCTION в локальных SQL.',
         'Отсутствие определения — пробел исходников, не доказательство отсутствия функции в production.',
         'Наличие SQL не доказывает применённую миграцию или правильность функции.', '',
         '| RPC | Определение в SQL | Клиентские файлы |','|---|---|---|']
for name, paths in sorted(calls.items()):
    lines.append(f"| {name} | {'Есть' if name in definitions else '**Не найдено**'} | {', '.join(sorted(paths))} |")
(root/'docs/RPC_SOURCE_INVENTORY_2026_10_29.md').write_text('\n'.join(lines)+'\n','utf-8')
print(f'{len(calls)} distinct RPC calls; {len(set(calls)-set(definitions))} without CREATE definition in repo')
