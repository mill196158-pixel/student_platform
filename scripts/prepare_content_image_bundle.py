#!/usr/bin/env python3
"""Prepare a *local-only* image optimization bundle with immutable originals.

This tool never calls Supabase and cannot publish or replace production objects.
Each bundle includes byte-identical originals, optional smaller JPEG derivatives,
SHA-256 hashes, and a manifest for a separately reviewed replacement operation.
Requires Pillow. An existing output directory is never overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError

MAX_SOURCE_BYTES = 20 * 1024 * 1024
MAX_TOTAL_BYTES = 100 * 1024 * 1024
MAX_PIXELS = 20_000_000
MAX_INPUTS = 50
MAX_DIMENSION = 1600
JPEG_QUALITY = 88


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _inspect_and_optimize(source: bytes) -> tuple[bytes | None, dict[str, Any]]:
    """Return a derivative only for images we can convert without losing alpha/profile."""
    if not source or len(source) > MAX_SOURCE_BYTES:
        raise ValueError('Source must be non-empty and at most 20 MiB')
    try:
        with Image.open(io.BytesIO(source)) as image:
            width, height = image.size
            if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
                return None, {'reason': 'pixel_budget', 'width': width, 'height': height}
            info: dict[str, Any] = {
                'format': image.format,
                'width': width,
                'height': height,
                'mode': image.mode,
            }
            if image.format not in ('JPEG', 'PNG', 'WEBP'):
                return None, {**info, 'reason': 'unsupported_format'}
            if getattr(image, 'is_animated', False) or getattr(image, 'n_frames', 1) != 1:
                return None, {**info, 'reason': 'animated'}
            if image.info.get('icc_profile'):
                return None, {**info, 'reason': 'color_profile'}
            if image.mode not in ('RGB', 'L') or 'transparency' in image.info:
                return None, {**info, 'reason': 'alpha_or_color_mode'}
            orientation = image.getexif().get(274, 1)
            if orientation != 1:
                return None, {**info, 'reason': 'non_upright_or_unknown_orientation'}
            image.load()
            img = image.convert('RGB')
            img.thumbnail((MAX_DIMENSION, MAX_DIMENSION), Image.Resampling.LANCZOS)
            out = io.BytesIO()
            img.save(out, format='JPEG', quality=JPEG_QUALITY, optimize=True, progressive=True)
            encoded = out.getvalue()
            if len(encoded) >= len(source):
                return None, {**info, 'reason': 'not_smaller'}
            return encoded, {**info, 'optimized_width': img.width,
                             'optimized_height': img.height}
    except (UnidentifiedImageError, OSError, ValueError) as error:
        raise ValueError('Input is not a safely decodable image') from error


def prepare_bundle(paths: list[Path], output: Path) -> dict[str, Any]:
    if not paths or len(paths) > MAX_INPUTS:
        raise ValueError('Specify between 1 and 50 source images')
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise FileExistsError('Output already exists; nothing was overwritten')
    if not output.parent.is_dir():
        raise ValueError('Output parent directory must already exist')
    prepared = []
    total = 0
    for path in paths:
        if not path.is_file():
            raise ValueError(f'Source is not a regular file: {path.name}')
        if path.stat().st_size > MAX_SOURCE_BYTES:
            raise ValueError(f'Source exceeds 20 MiB: {path.name}')
        source = path.read_bytes()
        total += len(source)
        if total > MAX_TOTAL_BYTES:
            raise ValueError('Combined input exceeds 100 MiB')
        derivative, details = _inspect_and_optimize(source)
        prepared.append((path.name, source, derivative, details))

    # Private temporary directory is created beside output so moves are local.
    staging = Path(tempfile.mkdtemp(prefix='.image-bundle-', dir=output.parent))
    created_names: list[str] = []
    try:
        entries = []
        for index, (name, source, derivative, details) in enumerate(prepared):
            original_name = f'{index:03d}-original.bin'
            (staging / original_name).write_bytes(source)
            created_names.append(original_name)
            record = {
                'source_name': name,
                'original': original_name,
                'original_bytes': len(source),
                'original_sha256': _sha256(source),
                'details': details,
            }
            if derivative is not None:
                optimized_name = f'{index:03d}-optimized.jpg'
                (staging / optimized_name).write_bytes(derivative)
                created_names.append(optimized_name)
                record.update({
                    'optimized': optimized_name,
                    'optimized_bytes': len(derivative),
                    'optimized_sha256': _sha256(derivative),
                    'optimized_mime': 'image/jpeg',
                })
            entries.append(record)
        manifest = {'schema': 1, 'publication': 'NOT_PUBLISHED', 'entries': entries}
        (staging / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        created_names.append('manifest.json')
        # mkdir, unlike rename on Unix, atomically fails if *any* target exists.
        # On interruption a partial directory has no manifest and is not usable.
        output.mkdir(mode=0o700)
        for name in created_names:
            os.rename(staging / name, output / name)
        return manifest
    finally:
        # Only clean files we created inside the known temp directory. Do not
        # recursively remove a computed directory or touch the output.
        for name in created_names:
            try:
                (staging / name).unlink(missing_ok=True)
            except OSError:
                pass
        try:
            staging.rmdir()
        except OSError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='A new local output directory')
    parser.add_argument('images', nargs='+', type=Path, help='Local source image paths')
    args = parser.parse_args()
    try:
        result = prepare_bundle(args.images, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Preparation failed: {error}\n')
    ready = sum('optimized' in item for item in result['entries'])
    print(f'Prepared {ready}/{len(result["entries"])} smaller images locally. Nothing was published.')


if __name__ == '__main__':
    main()
