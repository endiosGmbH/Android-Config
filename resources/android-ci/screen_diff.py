#!/usr/bin/env python3
"""Before / After / Diff report for screenshot tests.

Two sub-commands, both used by `androidScreenDiff` in the android-ci library:

  compare  Pixel-compares same-named PNGs in a "before" and an "after" folder,
           sorts each screen into unchanged / changed / new / removed, writes
           diff images and a static HTML report (index.html + report.css +
           images/), plus summary.json and a one-line summary.txt.

  comment  Creates or updates one bot comment on a GitHub pull request with the
           counts and a link to the report. The token comes from the
           GITHUB_TOKEN environment variable, never from the command line.

Only the Python standard library is required (Python 3.8+). If Pillow is
installed it is used to decode PNGs faster; the result is the same.

A pixel change never makes `compare` exit non-zero: it is reported for review.
Exit code 2 means the tool itself could not run (bad arguments, unreadable folder).
"""

import argparse
import html
import json
import os
import re
import shutil
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import zlib

COMMENT_MARKER = '<!-- android-ci:screen-diff -->'

STATUS_CHANGED = 'changed'
STATUS_NEW = 'new'
STATUS_REMOVED = 'removed'
STATUS_UNCHANGED = 'unchanged'

# Diff image: changed pixels are this colour; unchanged pixels show the "after"
# screen washed out towards white so the change stands out but stays in context.
DIFF_RGBA = bytes((255, 0, 60, 255))
_WASH = bytes(255 - (255 - v) // 4 for v in range(256))

_PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'


# --------------------------------------------------------------------------- PNG

class PngError(Exception):
    pass


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(data, height, stride, bpp):
    """Reverses the per-row PNG filters. Returns a list of `height` bytearrays."""
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        if pos + 1 + stride > len(data):
            raise PngError('truncated image data')
        ftype = data[pos]
        row = bytearray(data[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:
            row = bytearray((a + b) & 0xFF for a, b in zip(row, prev))
        elif ftype == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                if i >= bpp:
                    row[i] = (row[i] + _paeth(row[i - bpp], prev[i], prev[i - bpp])) & 0xFF
                else:
                    row[i] = (row[i] + prev[i]) & 0xFF
        else:
            raise PngError('unknown filter type %d' % ftype)
        rows.append(row)
        prev = row
    return rows


def _samples(row, width, channels, depth):
    """Unpacks one row into a list of integer samples (width * channels)."""
    count = width * channels
    if depth == 8:
        return row[:count]
    if depth == 16:
        return [(row[2 * i] << 8) | row[2 * i + 1] for i in range(count)]
    per_byte = 8 // depth
    mask = (1 << depth) - 1
    out = []
    for i in range(count):
        byte = row[i // per_byte]
        shift = 8 - depth * (i % per_byte + 1)
        out.append((byte >> shift) & mask)
    return out


def _decode_stdlib(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    if not raw.startswith(_PNG_SIGNATURE):
        raise PngError('not a PNG file')
    pos = len(_PNG_SIGNATURE)
    ihdr = None
    palette = None
    trns = None
    idat = []
    while pos + 8 <= len(raw):
        length, ctype = struct.unpack('>I4s', raw[pos:pos + 8])
        body = raw[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif ctype == b'PLTE':
            palette = body
        elif ctype == b'tRNS':
            trns = body
        elif ctype == b'IDAT':
            idat.append(body)
        elif ctype == b'IEND':
            break
    if ihdr is None:
        raise PngError('missing IHDR')
    width, height, depth, color, _, _, interlace = ihdr
    if interlace:
        raise PngError('interlaced PNGs are not supported without Pillow')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if channels is None:
        raise PngError('unknown colour type %d' % color)
    bits_per_pixel = channels * depth
    stride = (width * bits_per_pixel + 7) // 8
    bpp = max(1, bits_per_pixel // 8)
    rows = _unfilter(zlib.decompress(b''.join(idat)), height, stride, bpp)

    if color == 6 and depth == 8:
        return width, height, b''.join(bytes(r) for r in rows)

    out = bytearray()
    max_value = (1 << depth) - 1
    for row in rows:
        s = _samples(row, width, channels, depth)
        if color == 3:
            if palette is None:
                raise PngError('palette image without PLTE')
            for idx in s:
                out += palette[3 * idx:3 * idx + 3]
                out.append(trns[idx] if trns is not None and idx < len(trns) else 255)
        elif color == 0:
            key = struct.unpack('>H', trns[:2])[0] if trns and len(trns) >= 2 else None
            for v in s:
                g = v * 255 // max_value
                out += bytes((g, g, g, 0 if v == key else 255))
        elif color == 4:
            for i in range(0, len(s), 2):
                g = s[i] * 255 // max_value
                out += bytes((g, g, g, s[i + 1] * 255 // max_value))
        elif color == 2:
            key = struct.unpack('>HHH', trns[:6]) if trns and len(trns) >= 6 else None
            for i in range(0, len(s), 3):
                px = (s[i], s[i + 1], s[i + 2])
                out += bytes(v * 255 // max_value for v in px)
                out.append(0 if px == key else 255)
        else:  # colour type 6, 16 bit
            for v in s:
                out.append(v * 255 // max_value)
    return width, height, bytes(out)


def _decode_pillow(path):
    from PIL import Image  # noqa: imported lazily, optional
    with Image.open(path) as img:
        img = img.convert('RGBA')
        return img.width, img.height, img.tobytes()


def read_png(path, use_pillow=None):
    """Returns (width, height, RGBA bytes)."""
    if use_pillow is None:
        use_pillow = _pillow_available()
    if use_pillow:
        return _decode_pillow(path)
    return _decode_stdlib(path)


def _pillow_available():
    try:
        import PIL.Image  # noqa: F401
        return True
    except ImportError:
        return False


def write_png(path, width, height, rgba):
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(ctype, body):
        crc = zlib.crc32(ctype + body) & 0xFFFFFFFF
        return struct.pack('>I', len(body)) + ctype + body + struct.pack('>I', crc)

    with open(path, 'wb') as fh:
        fh.write(_PNG_SIGNATURE)
        fh.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)))
        fh.write(chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        fh.write(chunk(b'IEND', b''))


# ----------------------------------------------------------------------- compare

def pixel_diff(before, after):
    """Compares two decoded images.

    `before` and `after` are (width, height, rgba). Returns
    (changed_pixels, total_pixels, (width, height, diff_rgba)). The diff canvas
    covers both sizes; pixels outside one of the images count as changed.
    """
    bw, bh, bpx = before
    aw, ah, apx = after
    width, height = max(bw, aw), max(bh, ah)
    changed = 0
    out = bytearray()
    for y in range(height):
        brow = bpx[y * bw * 4:(y + 1) * bw * 4] if y < bh else b''
        arow = apx[y * aw * 4:(y + 1) * aw * 4] if y < ah else b''
        if bw == aw == width and brow == arow:
            out += arow.translate(_WASH)
            continue
        for x in range(width):
            b = brow[x * 4:x * 4 + 4] if x < bw and brow else None
            a = arow[x * 4:x * 4 + 4] if x < aw and arow else None
            if a is not None and a == b:
                out += a.translate(_WASH)
            else:
                changed += 1
                out += DIFF_RGBA
    return changed, width * height, (width, height, bytes(out))


def collect_pngs(folder):
    """Maps screen id (relative path without .png, '/'-separated) to file path."""
    found = {}
    if not folder or not os.path.isdir(folder):
        return found
    for root, _, files in os.walk(folder):
        for name in files:
            if not name.lower().endswith('.png'):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, folder).replace(os.sep, '/')
            found[rel[:-4]] = full
    return found


def _same_bytes(path_a, path_b):
    if os.path.getsize(path_a) != os.path.getsize(path_b):
        return False
    with open(path_a, 'rb') as fa, open(path_b, 'rb') as fb:
        return fa.read() == fb.read()


def compare_folders(before_dir, after_dir, out_dir, threshold=0.0, use_pillow=None):
    """Compares the folders and copies the report images into out_dir/images.

    `threshold` is the largest fraction (0..1) of differing pixels that still
    counts as unchanged. 0 means any differing pixel marks the screen changed.
    Returns the list of screen entries, sorted by id.
    """
    before = collect_pngs(before_dir)
    after = collect_pngs(after_dir)
    images = os.path.join(out_dir, 'images')
    screens = []
    for sid in sorted(set(before) | set(after)):
        entry = {'id': sid}
        b, a = before.get(sid), after.get(sid)
        if b and not a:
            entry['status'] = STATUS_REMOVED
            entry['before'] = _copy(b, images, 'before', sid)
        elif a and not b:
            entry['status'] = STATUS_NEW
            entry['after'] = _copy(a, images, 'after', sid)
        elif _same_bytes(a, b):
            entry['status'] = STATUS_UNCHANGED
            entry['changedPixels'] = 0
        else:
            _compare_pair(entry, b, a, images, threshold, use_pillow)
        screens.append(entry)
    return screens


def _compare_pair(entry, before_path, after_path, images, threshold, use_pillow):
    try:
        bimg = read_png(before_path, use_pillow)
        aimg = read_png(after_path, use_pillow)
    except Exception as err:  # undecodable: report it, never hide a possible change
        entry['status'] = STATUS_CHANGED
        entry['note'] = 'could not decode PNG (%s); files differ byte-wise' % err
        entry['before'] = _copy(before_path, images, 'before', entry['id'])
        entry['after'] = _copy(after_path, images, 'after', entry['id'])
        return
    changed, total, diff = pixel_diff(bimg, aimg)
    entry['changedPixels'] = changed
    entry['totalPixels'] = total
    entry['changedRatio'] = changed / total if total else 0.0
    if (bimg[0], bimg[1]) != (aimg[0], aimg[1]):
        entry['note'] = 'size changed from %dx%d to %dx%d' % (bimg[0], bimg[1], aimg[0], aimg[1])
    if changed == 0 or (entry['changedRatio'] <= threshold and 'note' not in entry):
        entry['status'] = STATUS_UNCHANGED
        return
    entry['status'] = STATUS_CHANGED
    entry['before'] = _copy(before_path, images, 'before', entry['id'])
    entry['after'] = _copy(after_path, images, 'after', entry['id'])
    diff_rel = 'images/diff/%s.png' % entry['id']
    diff_path = os.path.join(images, 'diff', *(entry['id'] + '.png').split('/'))
    os.makedirs(os.path.dirname(diff_path), exist_ok=True)
    write_png(diff_path, *diff)
    entry['diff'] = diff_rel


def _copy(src, images, kind, sid):
    dest = os.path.join(images, kind, *(sid + '.png').split('/'))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(src, dest)
    return 'images/%s/%s.png' % (kind, sid)


def count(screens):
    counts = {s: 0 for s in (STATUS_CHANGED, STATUS_NEW, STATUS_REMOVED, STATUS_UNCHANGED)}
    for entry in screens:
        counts[entry['status']] += 1
    return counts


# ------------------------------------------------------------------------ report

REPORT_CSS = """
:root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#5d6675; --line:#dfe3ea;
  --changed:#c2410c; --new:#047857; --removed:#b91c1c; --unchanged:#475569; --warn-bg:#fff4e5; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14171c; --card:#1d2128; --text:#e7eaf0; --muted:#9aa3b2; --line:#2e343e;
    --changed:#fb923c; --new:#34d399; --removed:#f87171; --unchanged:#94a3b8; --warn-bg:#3a2a12; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text);
  font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width:1280px; margin:0 auto; padding:24px 16px 64px; }
h1 { font-size:22px; margin:0 0 4px; }
h2 { font-size:18px; margin:32px 0 12px; }
.meta { color:var(--muted); margin:0 0 16px; }
.counts { display:flex; flex-wrap:wrap; gap:8px; margin:16px 0; }
.count { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:8px 14px; }
.count b { font-size:20px; margin-right:6px; }
.count.changed b { color:var(--changed); } .count.new b { color:var(--new); }
.count.removed b { color:var(--removed); } .count.unchanged b { color:var(--unchanged); }
.warn { background:var(--warn-bg); border:1px solid var(--changed); border-radius:8px; padding:10px 14px; margin:8px 0; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; margin:0 0 16px; }
.card h3 { font-size:15px; margin:0 0 4px; font-family:ui-monospace, Menlo, monospace; word-break:break-all; }
.card .note { color:var(--muted); margin:0 0 10px; font-size:13px; }
.shots { display:grid; grid-template-columns:repeat(3, minmax(0, 360px)); gap:12px; }
.shots.single { grid-template-columns:minmax(0, 360px); }
figure { margin:0; }
figcaption { font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); margin-bottom:4px; }
figure img { width:100%; height:auto; border:1px solid var(--line); border-radius:6px; background:repeating-conic-gradient(#ccc 0 25%, #fff 0 50%) 0 0/16px 16px; }
.lightbox { display:none; position:fixed; inset:0; background:rgba(0,0,0,.88); z-index:10; padding:24px; }
.lightbox:target { display:flex; align-items:center; justify-content:center; }
.lightbox img { max-width:100%; max-height:100%; border:0; }
.lightbox .close { position:absolute; top:12px; right:20px; color:#fff; font-size:28px; text-decoration:none; }
ul.plain { padding-left:18px; font-family:ui-monospace, Menlo, monospace; font-size:13px; }
@media (max-width: 720px) { .shots { grid-template-columns:minmax(0, 1fr); } }
"""


def _figure(caption, rel, anchor):
    src = html.escape(urllib.parse.quote(rel))
    return ('<figure><figcaption>%s</figcaption><a href="#%s"><img src="%s" alt="%s" loading="lazy"></a>'
            '<div class="lightbox" id="%s"><a class="close" href="#">&times;</a>'
            '<a href="#"><img src="%s" alt="%s"></a></div></figure>'
            % (caption, anchor, src, caption, anchor, src, caption))


def render_html(screens, meta):
    counts = count(screens)
    title = meta.get('title') or 'Screen diff'
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width, initial-scale=1">',
             '<title>%s</title><link rel="stylesheet" href="report.css"></head><body><main>' % html.escape(title),
             '<h1>%s</h1>' % html.escape(title)]
    if meta.get('subtitle'):
        parts.append('<p class="meta">%s</p>' % html.escape(meta['subtitle']))
    parts.append('<div class="counts">')
    for key in (STATUS_CHANGED, STATUS_NEW, STATUS_REMOVED, STATUS_UNCHANGED):
        parts.append('<div class="count %s"><b>%d</b>%s</div>' % (key, counts[key], key))
    parts.append('</div>')
    for warning in meta.get('warnings', []):
        parts.append('<div class="warn">%s</div>' % html.escape(warning))

    n = 0
    sections = (
        (STATUS_CHANGED, 'Changed', (('Before', 'before'), ('After', 'after'), ('Diff', 'diff'))),
        (STATUS_NEW, 'New', (('After', 'after'),)),
        (STATUS_REMOVED, 'Removed', (('Before', 'before'),)),
    )
    for status, heading, shots in sections:
        items = [s for s in screens if s['status'] == status]
        if not items:
            continue
        parts.append('<h2>%s (%d)</h2>' % (heading, len(items)))
        for entry in items:
            parts.append('<section class="card"><h3>%s</h3>' % html.escape(entry['id']))
            notes = []
            if entry.get('changedPixels'):
                notes.append('%d of %d pixels differ (%.3f%%)' % (
                    entry['changedPixels'], entry['totalPixels'], 100.0 * entry['changedRatio']))
            if entry.get('note'):
                notes.append(entry['note'])
            if notes:
                parts.append('<p class="note">%s</p>' % html.escape(' · '.join(notes)))
            parts.append('<div class="shots%s">' % ('' if len(shots) > 1 else ' single'))
            for caption, key in shots:
                if entry.get(key):
                    n += 1
                    parts.append(_figure(caption, entry[key], 'img%d' % n))
            parts.append('</div></section>')

    unchanged = [s['id'] for s in screens if s['status'] == STATUS_UNCHANGED]
    if unchanged:
        parts.append('<h2>Unchanged (%d)</h2><details><summary>Show screen names</summary><ul class="plain">'
                     % len(unchanged))
        parts.extend('<li>%s</li>' % html.escape(sid) for sid in unchanged)
        parts.append('</ul></details>')
    if not screens:
        parts.append('<p>No screenshots were found in either run.</p>')
    parts.append('</main></body></html>\n')
    return ''.join(parts)


def write_report(out_dir, screens, meta):
    os.makedirs(out_dir, exist_ok=True)
    counts = count(screens)
    with open(os.path.join(out_dir, 'index.html'), 'w', encoding='utf-8') as fh:
        fh.write(render_html(screens, meta))
    # Separate stylesheet, not inline: Jenkins serves archived artifacts with a
    # Content-Security-Policy that blocks inline <style> (style-src 'self').
    with open(os.path.join(out_dir, 'report.css'), 'w', encoding='utf-8') as fh:
        fh.write(REPORT_CSS.lstrip())
    summary = {'counts': counts, 'screens': screens, 'meta': meta}
    with open(os.path.join(out_dir, 'summary.json'), 'w', encoding='utf-8') as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
    with open(os.path.join(out_dir, 'summary.txt'), 'w', encoding='utf-8') as fh:
        fh.write(' '.join('%s=%d' % (k, counts[k]) for k in
                          (STATUS_CHANGED, STATUS_NEW, STATUS_REMOVED, STATUS_UNCHANGED)) + '\n')
    return counts


# ----------------------------------------------------------------------- comment

def parse_pr_url(url):
    """'https://github.com/owner/repo/pull/12' -> ('owner', 'repo', 12)."""
    match = re.match(r'https?://github\.com/([^/]+)/([^/]+)/pull/(\d+)', url or '')
    if not match:
        raise ValueError('not a GitHub pull request URL: %r' % url)
    return match.group(1), match.group(2), int(match.group(3))


def comment_body(summary, report_url, build_label=None, statuses=None, max_listed=15):
    counts = summary['counts']
    lines = [COMMENT_MARKER, '### Screen diff', '',
             '| Changed | New | Removed | Unchanged |', '|---:|---:|---:|---:|',
             '| %d | %d | %d | %d |' % (counts[STATUS_CHANGED], counts[STATUS_NEW],
                                         counts[STATUS_REMOVED], counts[STATUS_UNCHANGED]),
             '']
    for status, label in ((STATUS_CHANGED, 'Changed'), (STATUS_NEW, 'New'), (STATUS_REMOVED, 'Removed')):
        ids = [s['id'] for s in summary['screens'] if s['status'] == status]
        if ids:
            shown = ', '.join('`%s`' % i for i in ids[:max_listed])
            more = ' and %d more' % (len(ids) - max_listed) if len(ids) > max_listed else ''
            lines.append('**%s:** %s%s' % (label, shown, more))
    for warning in summary.get('meta', {}).get('warnings', []):
        lines.append('> :warning: %s' % warning)
    if statuses:
        lines.append('')
        lines.append(' · '.join('%s: **%s**' % (k, v) for k, v in statuses))
    lines.append('')
    link = '[Open the Before / After / Diff report](%s)' % report_url
    lines.append(link + (' · %s' % build_label if build_label else ''))
    return '\n'.join(lines) + '\n'


def _github(method, url, token, payload=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer %s' % token)
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('X-GitHub-Api-Version', '2022-11-28')
    req.add_header('User-Agent', 'android-ci-screen-diff')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode('utf-8')
        return json.loads(body) if body else None


def upsert_comment(owner, repo, number, body, token, api='https://api.github.com', request=_github):
    """Updates the comment carrying COMMENT_MARKER, or creates it. Returns 'updated' or 'created'."""
    base = '%s/repos/%s/%s' % (api, owner, repo)
    existing = None
    for page in range(1, 11):
        comments = request('GET', '%s/issues/%d/comments?per_page=100&page=%d' % (base, number, page), token)
        for c in comments or []:
            if COMMENT_MARKER in (c.get('body') or ''):
                existing = c
        if not comments or len(comments) < 100:
            break
    if existing:
        request('PATCH', '%s/issues/comments/%d' % (base, existing['id']), token, {'body': body})
        return 'updated'
    request('POST', '%s/issues/%d/comments' % (base, number), token, {'body': body})
    return 'created'


# --------------------------------------------------------------------------- CLI

def _cmd_compare(args):
    for folder in (args.before, args.after):
        if folder and os.path.exists(folder) and not os.path.isdir(folder):
            print('not a folder: %s' % folder, file=sys.stderr)
            return 2
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)
    screens = compare_folders(args.before, args.after, args.out, args.threshold)
    meta = {'title': args.title, 'subtitle': args.subtitle, 'threshold': args.threshold,
            'warnings': args.warning or []}
    counts = write_report(args.out, screens, meta)
    print('Screen diff: %s' % ', '.join('%s=%d' % kv for kv in sorted(counts.items())))
    print('Report: %s' % os.path.join(args.out, 'index.html'))
    return 0


def _cmd_comment(args):
    with open(args.summary, encoding='utf-8') as fh:
        summary = json.load(fh)
    statuses = [tuple(s.split('=', 1)) for s in (args.status or []) if '=' in s]
    body = comment_body(summary, args.report_url, args.build_label, statuses)
    if args.dry_run:
        print(body)
        return 0
    token = os.environ.get('GITHUB_TOKEN')
    if not token:
        print('GITHUB_TOKEN is not set; not commenting.', file=sys.stderr)
        return 2
    owner, repo, number = parse_pr_url(args.pr_url)
    try:
        result = upsert_comment(owner, repo, number, body, token)
    except urllib.error.HTTPError as err:
        print('GitHub API error %s: %s' % (err.code, err.read().decode('utf-8', 'replace')[:500]), file=sys.stderr)
        return 2
    print('PR comment %s on %s/%s#%d' % (result, owner, repo, number))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command')

    cmp_p = sub.add_parser('compare', help='compare two screenshot folders and write the report')
    cmp_p.add_argument('--before', required=True, help='screenshots of the base branch')
    cmp_p.add_argument('--after', required=True, help='screenshots of the pull request')
    cmp_p.add_argument('--out', required=True, help='report folder (wiped first)')
    cmp_p.add_argument('--threshold', type=float, default=0.0,
                       help='largest fraction of differing pixels still counted as unchanged (default 0)')
    cmp_p.add_argument('--title', default='Screen diff')
    cmp_p.add_argument('--subtitle', default='')
    cmp_p.add_argument('--warning', action='append', help='banner shown in the report and the PR comment')

    com_p = sub.add_parser('comment', help='create or update the PR comment')
    com_p.add_argument('--summary', required=True, help='summary.json written by compare')
    com_p.add_argument('--report-url', required=True)
    com_p.add_argument('--pr-url', default='', help='https://github.com/<owner>/<repo>/pull/<n>')
    com_p.add_argument('--build-label', default='')
    com_p.add_argument('--status', action='append', help='"Label=value" shown under the counts')
    com_p.add_argument('--dry-run', action='store_true', help='print the comment instead of posting')

    args = parser.parse_args(argv)
    if args.command == 'compare':
        if not 0.0 <= args.threshold <= 1.0:
            parser.error('--threshold must be between 0 and 1')
        return _cmd_compare(args)
    if args.command == 'comment':
        return _cmd_comment(args)
    parser.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main())
