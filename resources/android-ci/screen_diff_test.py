#!/usr/bin/env python3
"""Unit tests for screen_diff.py. Run: python3 resources/android-ci/screen_diff_test.py

Only the standard library is needed. Tests that cross-check against Pillow are
skipped when Pillow is not installed.
"""

import contextlib
import io
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screen_diff as sd  # noqa: E402

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None


def solid(width, height, rgba):
    return bytes(rgba) * (width * height)


def with_pixel(width, height, base, x, y, rgba):
    px = bytearray(base)
    i = (y * width + x) * 4
    px[i:i + 4] = bytes(rgba)
    return bytes(px)


def write_raw_png(path, width, height, color, depth, rows, filters, palette=None, trns=None):
    """Writes a PNG from already-packed rows, with a chosen filter byte per row (pre-filtered by caller)."""
    def chunk(ctype, body):
        return struct.pack('>I', len(body)) + ctype + body + struct.pack('>I', zlib.crc32(ctype + body) & 0xFFFFFFFF)
    raw = b''.join(bytes([f]) + r for f, r in zip(filters, rows))
    with open(path, 'wb') as fh:
        fh.write(sd._PNG_SIGNATURE)
        fh.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, 0)))
        if palette:
            fh.write(chunk(b'PLTE', palette))
        if trns:
            fh.write(chunk(b'tRNS', trns))
        fh.write(chunk(b'IDAT', zlib.compress(raw)))
        fh.write(chunk(b'IEND', b''))


class PngCodecTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_round_trip(self):
        px = bytes(range(256)) * 12  # 4x4 RGBA... 3072 bytes = 768 px
        path = os.path.join(self.tmp, 'a.png')
        sd.write_png(path, 32, 24, px)
        self.assertEqual(sd.read_png(path, use_pillow=False), (32, 24, px))

    def test_all_filters_rgba(self):
        # Row values chosen so every filter type changes the bytes; encode by applying
        # the filters forward, then check the decoder reverses them.
        width, height, bpp = 3, 5, 4
        rows = [bytes((x * 40 + y * 13 + c * 7) % 256 for x in range(width) for c in range(4)) for y in range(height)]
        filtered, prev = [], bytes(width * bpp)
        for ftype, row in enumerate(rows):
            out = bytearray()
            for i, v in enumerate(row):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pred = [0, a, b, (a + b) // 2, sd._paeth(a, b, c)][ftype]
                out.append((v - pred) & 0xFF)
            filtered.append(bytes(out))
            prev = row
        path = os.path.join(self.tmp, 'f.png')
        write_raw_png(path, width, height, 6, 8, filtered, list(range(5)))
        self.assertEqual(sd.read_png(path, use_pillow=False)[2], b''.join(rows))

    def test_palette_with_transparency(self):
        path = os.path.join(self.tmp, 'p.png')
        palette = bytes((255, 0, 0, 0, 255, 0))
        # 2-bit palette, 4 px wide: indices 0,1,1,0 -> 0b00010100
        write_raw_png(path, 4, 1, 3, 2, [bytes([0b00010100])], [0], palette=palette, trns=bytes([0]))
        w, h, px = sd.read_png(path, use_pillow=False)
        self.assertEqual((w, h), (4, 1))
        self.assertEqual(px, bytes((255, 0, 0, 0, 0, 255, 0, 255, 0, 255, 0, 255, 255, 0, 0, 0)))

    def test_gray16_and_rgb8(self):
        path = os.path.join(self.tmp, 'g.png')
        write_raw_png(path, 2, 1, 0, 16, [struct.pack('>HH', 0xFFFF, 0)], [0])
        self.assertEqual(sd.read_png(path, use_pillow=False)[2], bytes((255, 255, 255, 255, 0, 0, 0, 255)))
        path = os.path.join(self.tmp, 'rgb.png')
        write_raw_png(path, 1, 1, 2, 8, [bytes((1, 2, 3))], [0])
        self.assertEqual(sd.read_png(path, use_pillow=False)[2], bytes((1, 2, 3, 255)))

    @unittest.skipIf(Image is None, 'Pillow not installed')
    def test_stdlib_decoder_matches_pillow(self):
        # Pillow picks its own filters and colour types; both decoders must agree.
        for mode in ('RGBA', 'RGB', 'L', 'P', 'LA'):
            img = Image.new('RGBA', (37, 23))
            img.putdata([((x * 7) % 256, (y * 11) % 256, (x * y) % 256, 255 if mode != 'LA' else (x * 9) % 256)
                         for y in range(23) for x in range(37)])
            path = os.path.join(self.tmp, mode + '.png')
            img.convert(mode).save(path)
            self.assertEqual(sd.read_png(path, use_pillow=False), sd.read_png(path, use_pillow=True), mode)


class CompareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.before = os.path.join(self.tmp, 'before')
        self.after = os.path.join(self.tmp, 'after')
        self.out = os.path.join(self.tmp, 'report')
        os.makedirs(self.before)
        os.makedirs(self.after)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def put(self, folder, name, width, height, px):
        sd.write_png(os.path.join(folder, name + '.png'), width, height, px)

    def run_compare(self, threshold=0.0):
        return {s['id']: s for s in sd.compare_folders(self.before, self.after, self.out, threshold)}

    def test_no_ui_change_reports_zero_changed(self):
        white = solid(20, 30, (255, 255, 255, 255))
        for name in ('meterreading.list__default', 'meterreading.form__validation-error'):
            self.put(self.before, name, 20, 30, white)
            self.put(self.after, name, 20, 30, white)
        screens = self.run_compare()
        self.assertEqual(sd.count(screens.values()),
                         {'changed': 0, 'new': 0, 'removed': 0, 'unchanged': 2})

    def test_pixel_equal_but_byte_different_is_unchanged(self):
        px = solid(10, 10, (1, 2, 3, 255))
        self.put(self.before, 's__a', 10, 10, px)
        # Same pixels, different encoding (RGB instead of RGBA, different compression).
        rows = [bytes((1, 2, 3)) * 10] * 10
        write_raw_png(os.path.join(self.after, 's__a.png'), 10, 10, 2, 8, rows, [0] * 10)
        self.assertEqual(self.run_compare()['s__a']['status'], 'unchanged')

    def test_all_four_statuses(self):
        white = solid(8, 8, (255, 255, 255, 255))
        self.put(self.before, 'same__default', 8, 8, white)
        self.put(self.after, 'same__default', 8, 8, white)
        self.put(self.before, 'form__error', 8, 8, white)
        self.put(self.after, 'form__error', 8, 8, with_pixel(8, 8, white, 3, 4, (0, 0, 0, 255)))
        self.put(self.after, 'brand__new', 8, 8, white)
        self.put(self.before, 'gone__old', 8, 8, white)
        screens = self.run_compare()
        self.assertEqual({k: v['status'] for k, v in screens.items()}, {
            'same__default': 'unchanged', 'form__error': 'changed', 'brand__new': 'new', 'gone__old': 'removed'})
        changed = screens['form__error']
        self.assertEqual(changed['changedPixels'], 1)
        for key in ('before', 'after', 'diff'):
            self.assertTrue(os.path.isfile(os.path.join(self.out, changed[key])), key)
        w, h, diff = sd.read_png(os.path.join(self.out, changed['diff']), use_pillow=False)
        self.assertEqual((w, h), (8, 8))
        self.assertEqual(diff[(4 * 8 + 3) * 4:(4 * 8 + 3) * 4 + 4], sd.DIFF_RGBA)
        self.assertEqual(diff[:4], bytes((255, 255, 255, 255)))  # unchanged white stays white
        self.assertTrue(os.path.isfile(os.path.join(self.out, screens['brand__new']['after'])))
        self.assertTrue(os.path.isfile(os.path.join(self.out, screens['gone__old']['before'])))
        self.assertNotIn('after', screens['same__default'])  # unchanged screens are not copied

    def test_threshold(self):
        white = solid(10, 10, (255, 255, 255, 255))
        self.put(self.before, 's__a', 10, 10, white)
        self.put(self.after, 's__a', 10, 10, with_pixel(10, 10, white, 0, 0, (0, 0, 0, 255)))
        self.assertEqual(self.run_compare(threshold=0.0)['s__a']['status'], 'changed')
        self.assertEqual(self.run_compare(threshold=0.01)['s__a']['status'], 'unchanged')
        self.assertEqual(self.run_compare(threshold=0.005)['s__a']['status'], 'changed')

    def test_size_change_is_always_changed(self):
        self.put(self.before, 's__a', 4, 4, solid(4, 4, (0, 0, 0, 255)))
        self.put(self.after, 's__a', 4, 6, solid(4, 6, (0, 0, 0, 255)))
        entry = self.run_compare(threshold=1.0)['s__a']
        self.assertEqual(entry['status'], 'changed')
        self.assertEqual(entry['changedPixels'], 8)
        self.assertIn('size changed', entry['note'])

    def test_undecodable_png_is_reported_as_changed(self):
        self.put(self.before, 's__a', 2, 2, solid(2, 2, (0, 0, 0, 255)))
        with open(os.path.join(self.after, 's__a.png'), 'wb') as fh:
            fh.write(b'not a png')
        entry = sd.compare_folders(self.before, self.after, self.out, 0.0, use_pillow=False)[0]
        self.assertEqual(entry['status'], 'changed')
        self.assertIn('could not decode', entry['note'])

    def test_missing_before_folder_marks_everything_new(self):
        shutil.rmtree(self.before)
        self.put(self.after, 's__a', 2, 2, solid(2, 2, (0, 0, 0, 255)))
        self.assertEqual(self.run_compare()['s__a']['status'], 'new')

    def test_cli_writes_report_files(self):
        white = solid(8, 8, (255, 255, 255, 255))
        self.put(self.before, 'form__error', 8, 8, white)
        self.put(self.after, 'form__error', 8, 8, with_pixel(8, 8, white, 1, 1, (0, 0, 0, 255)))
        with contextlib.redirect_stdout(io.StringIO()):
            code = sd.main(['compare', '--before', self.before, '--after', self.after, '--out', self.out,
                            '--title', 'Demo <b>', '--warning', 'base run failed'])
        self.assertEqual(code, 0)
        for name in ('index.html', 'report.css', 'summary.json', 'summary.txt'):
            self.assertTrue(os.path.isfile(os.path.join(self.out, name)), name)
        with open(os.path.join(self.out, 'summary.txt')) as fh:
            self.assertEqual(fh.read().strip(), 'changed=1 new=0 removed=0 unchanged=0')
        with open(os.path.join(self.out, 'index.html')) as fh:
            page = fh.read()
        self.assertIn('Demo &lt;b&gt;', page)
        self.assertIn('images/diff/form__error.png', page)
        self.assertIn('base run failed', page)
        self.assertNotIn('<style', page)
        self.assertNotIn('<script', page)


class CommentTest(unittest.TestCase):
    summary = {
        'counts': {'changed': 1, 'new': 1, 'removed': 0, 'unchanged': 4},
        'screens': [{'id': 'form__error', 'status': 'changed'}, {'id': 'x__new', 'status': 'new'}],
        'meta': {'warnings': ['base run failed']},
    }

    def test_parse_pr_url(self):
        self.assertEqual(sd.parse_pr_url('https://github.com/endiosGmbH/oneWidget-Android/pull/42'),
                         ('endiosGmbH', 'oneWidget-Android', 42))
        with self.assertRaises(ValueError):
            sd.parse_pr_url('https://example.com/x')

    def test_body(self):
        body = sd.comment_body(self.summary, 'https://ci/report/index.html', 'build #7',
                               [('Snapshot tests', 'passed'), ('Flow tests', 'failed')])
        self.assertTrue(body.startswith(sd.COMMENT_MARKER))
        self.assertIn('| 1 | 1 | 0 | 4 |', body)
        self.assertIn('**Changed:** `form__error`', body)
        self.assertIn('**New:** `x__new`', body)
        self.assertIn(':warning: base run failed', body)
        self.assertIn('Flow tests: **failed**', body)
        self.assertIn('(https://ci/report/index.html) · build #7', body)

    def fake_api(self, comments):
        calls = []

        def request(method, url, token, payload=None):
            calls.append((method, url, payload))
            if method == 'GET':
                return comments if url.endswith('page=1') else []
            return {}
        return calls, request

    def test_upsert_updates_existing_bot_comment(self):
        calls, request = self.fake_api([{'id': 5, 'body': 'hello'}, {'id': 9, 'body': sd.COMMENT_MARKER + '\nold'}])
        self.assertEqual(sd.upsert_comment('o', 'r', 3, 'new body', 't', request=request), 'updated')
        self.assertEqual(calls[-1], ('PATCH', 'https://api.github.com/repos/o/r/issues/comments/9',
                                     {'body': 'new body'}))

    def test_upsert_creates_when_missing(self):
        calls, request = self.fake_api([{'id': 5, 'body': 'hello'}])
        self.assertEqual(sd.upsert_comment('o', 'r', 3, 'b', 't', request=request), 'created')
        self.assertEqual(calls[-1], ('POST', 'https://api.github.com/repos/o/r/issues/3/comments', {'body': 'b'}))

    def test_comment_cli_dry_run_needs_no_token(self):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, 'summary.json')
            with open(path, 'w') as fh:
                json.dump(self.summary, fh)
            env = os.environ.pop('GITHUB_TOKEN', None)
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(sd.main(['comment', '--summary', path, '--report-url', 'u', '--dry-run']), 0)
                    self.assertEqual(sd.main(['comment', '--summary', path, '--report-url', 'u',
                                              '--pr-url', 'https://github.com/o/r/pull/1']), 2)
                self.assertIn(sd.COMMENT_MARKER, out.getvalue())
            finally:
                if env is not None:
                    os.environ['GITHUB_TOKEN'] = env
        finally:
            shutil.rmtree(tmp)


if __name__ == '__main__':
    unittest.main()
