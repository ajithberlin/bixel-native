"""JSON adapter for the existing smart-split script; output naming is backend-owned."""
import importlib.util
from pathlib import Path
import sys

from PIL import Image

spec = importlib.util.spec_from_file_location('smart_split', Path(__file__).parent / 'scripts' / 'smart_split.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        argv = ['smart_split', str(source), '--mode', arguments['mode'],
                '--out', str(context.root), '--dilate', str(arguments['dilate']),
                '--min-area', str(arguments['min_area']), '--pad', str(arguments['pad'])]
        if arguments['cols']:
            argv += ['--cols', str(arguments['cols'])]
        if arguments['rows']:
            argv += ['--rows', str(arguments['rows'])]
        if arguments['insets']:
            argv += ['--insets', *arguments['insets'].split(',')]
        sys.argv = argv
        context.progress(0.1, 'Splitting image into pieces with existing Python skill')
        code = implementation.main()
        if code == 1:
            raise ValueError('Splitting failed')
    finally:
        sys.argv = original
    pieces = sorted(Path(context.root).glob('*.png'))[:15]
    manifest = Path(context.root) / 'manifest.json'
    warnings = ''
    mode = arguments['mode']
    if manifest.is_file():
        import json
        try:
            data = json.loads(manifest.read_text('utf-8'))
            mode = data.get('mode', mode)
            warnings = '; '.join(getattr(implementation, 'WARNINGS', []))[:2000]
        except ValueError:
            pass
    with Image.open(source) as image:
        width, height = image.size
    return {'data': {'mode': mode, 'piece_count': len(pieces), 'width': width,
                     'height': height, 'warnings': warnings},
            'artifacts': [{'name': piece.name, 'media_type': 'image/png'} for piece in pieces]}
