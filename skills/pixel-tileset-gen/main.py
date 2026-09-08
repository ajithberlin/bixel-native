"""JSON adapter for the existing Wang verifier; tile filenames are backend-owned."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('verify_wang', Path(__file__).parent / 'scripts' / 'verify_wang.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        report = context.output_path('seams.json')
        annotated = context.output_path('seams.png')
        argv = ['verify_wang', str(source), '--tile', str(arguments['tile']),
                '--tolerance', str(arguments['tolerance']),
                '--annotated', str(annotated), '--report', str(report),
                '--tiles', str(context.root)]
        if arguments['cols']:
            argv += ['--cols', str(arguments['cols'])]
        if arguments['rows']:
            argv += ['--rows', str(arguments['rows'])]
        sys.argv = argv
        context.progress(0.1, 'Verifying Wang seams with existing Python skill')
        code = implementation.main()
    finally:
        sys.argv = original
    pieces = sorted(Path(context.root).glob('*.png'))[:64]
    data = {'cols': arguments['cols'] or 0, 'rows': arguments['rows'] or 0,
            'tile': arguments['tile'], 'seams_total': 0, 'seams_bad': 0, 'ok_percent': 0.0}
    if report.is_file():
        try:
            info = json.loads(report.read_text('utf-8'))
            data.update({'cols': info.get('cols', data['cols']), 'rows': info.get('rows', data['rows']),
                         'seams_total': info.get('seams_total', 0),
                         'seams_bad': info.get('seams_bad', 0)})
            total = info.get('seams_total', 0)
            data['ok_percent'] = round(100.0 * (total - info.get('seams_bad', 0)) / max(total, 1), 1)
        except ValueError:
            pass
    return {'data': data,
            'artifacts': [{'name': piece.name, 'media_type': 'image/png'} for piece in pieces]}
