"""JSON adapter for the existing UI slicer; arguments and filenames are backend-owned."""
import importlib.util
from pathlib import Path
import sys

from PIL import Image

spec = importlib.util.spec_from_file_location('slice_ui', Path(__file__).parent / 'scripts' / 'slice_ui.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        argv = ['slice_ui', str(source), '--out', str(context.root),
                '--dilate', str(arguments['dilate']),
                '--min-area', str(arguments['min_area']), '--pad', str(arguments['pad'])]
        if arguments.get('names'):
            argv += ['--names', arguments['names']]
        sys.argv = argv
        context.progress(0.1, 'Slicing UI components with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('UI slicing failed')
    finally:
        sys.argv = original
    pieces = sorted(Path(context.root).glob('*.png'))[:16]
    with Image.open(source) as image:
        width, height = image.size
    return {'data': {'component_count': len(pieces), 'width': width, 'height': height},
            'artifacts': [{'name': piece.name, 'media_type': 'image/png'} for piece in pieces]}
