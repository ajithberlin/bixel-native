"""JSON adapter for the existing split-group script; crop filenames are backend-owned."""
import importlib.util
from pathlib import Path
import sys

from PIL import Image

spec = importlib.util.spec_from_file_location('split_group', Path(__file__).parent / 'scripts' / 'split_group.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        argv = ['split_group', str(source), str(context.root),
                '--names', arguments['names'], '--bg', arguments['bg'],
                '--tol', str(arguments['tol']), '--bridge', str(arguments['bridge']),
                '--margin', str(arguments['margin'])]
        sys.argv = argv
        context.progress(0.1, 'Splitting UI batch sheet with existing Python skill')
        try:
            implementation.main()
        except SystemExit as exc:
            if exc.code:
                raise ValueError('Sheet did not split cleanly; check names/grid') from exc
    finally:
        sys.argv = original
    pieces = sorted(Path(context.root).glob('*.png'))[:16]
    with Image.open(source) as image:
        width, height = image.size
    return {'data': {'piece_count': len(pieces), 'width': width, 'height': height},
            'artifacts': [{'name': piece.name, 'media_type': 'image/png'} for piece in pieces]}
