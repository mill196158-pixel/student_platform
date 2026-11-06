import hashlib
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from PIL import Image

MODULE = Path(__file__).resolve().parents[1] / 'prepare_content_image_bundle.py'
spec = importlib.util.spec_from_file_location('prepare_content_image_bundle', MODULE)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_photo_is_smaller_but_original_is_byte_identical(self):
        source = self.root / 'photo.jpg'
        Image.effect_noise((2000, 1300), 50).convert('RGB').save(source, 'JPEG', quality=98)
        before = source.read_bytes()
        out = self.root / 'bundle'
        manifest = bundle.prepare_bundle([source], out)
        item = manifest['entries'][0]
        original = (out / item['original']).read_bytes()
        derivative = (out / item['optimized']).read_bytes()
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(original, before)
        self.assertEqual(item['original_sha256'], hashlib.sha256(before).hexdigest())
        self.assertEqual(item['optimized_sha256'], hashlib.sha256(derivative).hexdigest())
        self.assertLess(len(derivative), len(before))
        with Image.open(out / item['optimized']) as result:
            self.assertEqual(result.format, 'JPEG')
            self.assertLessEqual(max(result.size), 1600)
        self.assertEqual(json.loads((out / 'manifest.json').read_text(encoding='utf8')), manifest)
        self.assertEqual(manifest['publication'], 'NOT_PUBLISHED')

    def test_transparent_png_is_preserved_without_a_derivative(self):
        source = self.root / 'transparent.png'
        Image.new('RGBA', (100, 100), (0, 0, 0, 0)).save(source)
        manifest = bundle.prepare_bundle([source], self.root / 'bundle')
        item = manifest['entries'][0]
        self.assertNotIn('optimized', item)
        self.assertEqual(item['details']['reason'], 'alpha_or_color_mode')
        self.assertEqual((self.root / 'bundle' / item['original']).read_bytes(), source.read_bytes())

    def test_non_upright_photo_is_preserved(self):
        source = self.root / 'rotated.jpg'
        exif = Image.Exif()
        exif[274] = 6
        Image.new('RGB', (120, 80), 'orange').save(source, exif=exif)
        item = bundle.prepare_bundle([source], self.root / 'bundle')['entries'][0]
        self.assertNotIn('optimized', item)
        self.assertEqual(item['details']['reason'], 'non_upright_or_unknown_orientation')

    def test_no_overwrite_and_invalid_source_never_creates_output(self):
        source = self.root / 'bad.jpg'
        source.write_bytes(b'not an image')
        with self.assertRaises(ValueError):
            bundle.prepare_bundle([source], self.root / 'absent')
        self.assertFalse((self.root / 'absent').exists())
        existing = self.root / 'existing'
        existing.mkdir()
        sentinel = existing / 'keep'
        sentinel.write_bytes(b'original')
        with self.assertRaises(FileExistsError):
            bundle.prepare_bundle([source], existing)
        self.assertEqual(sentinel.read_bytes(), b'original')

    def test_two_identical_names_keep_separate_originals(self):
        left, right = self.root / 'left', self.root / 'right'
        left.mkdir()
        right.mkdir()
        Image.new('RGB', (40, 40), 'red').save(left / 'same.png')
        Image.new('RGB', (40, 40), 'blue').save(right / 'same.png')
        out = self.root / 'bundle'
        items = bundle.prepare_bundle([left / 'same.png', right / 'same.png'], out)['entries']
        self.assertNotEqual(items[0]['original'], items[1]['original'])
        self.assertEqual((out / items[0]['original']).read_bytes(), (left / 'same.png').read_bytes())
        self.assertEqual((out / items[1]['original']).read_bytes(), (right / 'same.png').read_bytes())

    def test_output_created_by_another_process_is_never_overwritten(self):
        source = self.root / 'photo.png'
        Image.new('RGB', (100, 100), 'red').save(source)
        output = self.root / 'bundle'
        original_mkdir = Path.mkdir
        def racing_mkdir(path, *args, **kwargs):
            if path == output:
                original_mkdir(path)
                (path / 'other-process').write_bytes(b'keep me')
            return original_mkdir(path, *args, **kwargs)
        with patch.object(Path, 'mkdir', racing_mkdir):
            with self.assertRaises(FileExistsError):
                bundle.prepare_bundle([source], output)
        self.assertEqual((output / 'other-process').read_bytes(), b'keep me')
        self.assertFalse((output / 'manifest.json').exists())

    def test_format_uses_image_header_not_filename_extension(self):
        source = self.root / 'mislabelled.png'
        Image.effect_noise((1200, 900), 60).convert('RGB').save(source, 'JPEG', quality=98)
        output = self.root / 'bundle'
        item = bundle.prepare_bundle([source], output)['entries'][0]
        self.assertEqual(item['details']['format'], 'JPEG')
        self.assertEqual(item['optimized_mime'], 'image/jpeg')


if __name__ == '__main__':
    unittest.main()
