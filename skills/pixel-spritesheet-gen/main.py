"""JSON adapter for the existing freeform pack script; atlas filenames are backend-owned."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('freeform_pack', Path(__file__).parent / 'scripts' / 'freeform_pack.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        atlas = context.output_path('atlas.png')
        meta = context.output_path('atlas.json')
        argv = ['freeform_pack', str(source), '--actions', arguments['actions'],
                '--out-image', str(atlas), '--out-json', str(meta),
                '--tol', str(arguments['tol']), '--min-area', str(arguments['min_area']),
                '--pivot', arguments['pivot'], '--snap', str(arguments['snap']),
                '--padding', str(arguments['padding']), '--edge-trim', str(arguments['edge_trim'])]
        sys.argv = argv
        context.progress(0.1, 'Packing sprites with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('Sprite packing failed')
    finally:
        sys.argv = original
    info = {}
    if meta.is_file():
        try:
            info = json.loads(meta.read_text('utf-8'))
        except ValueError:
            pass
    actions = info.get('actions', {})
    sprite_count = sum(len(value.get('frames', [])) for value in actions.values())
    cell = info.get('cell', {})
    size = info.get('size', {})
    data = {'sprite_count': sprite_count, 'width': size.get('w', 0), 'height': size.get('h', 0),
            'cell_width': cell.get('w', 0), 'cell_height': cell.get('h', 0),
            'layout': info.get('layout', 'freeform')}
    return {'data': data, 'artifacts': [{'name': 'atlas.png', 'media_type': 'image/png'}]}
