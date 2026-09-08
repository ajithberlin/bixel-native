"""JSON adapter for the existing 8-direction packer.

The worker writes inputs as ``input-N``, but pack_8dir reads the facing
direction from each filename. Copy the supported frames into direction-named
files in a staging directory, then run the packer with ``--dir``.
"""
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('pack_8dir', Path(__file__).parent / 'scripts' / 'pack_8dir.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)

_DIRECTIONS = [('input', 'S'), ('frame_sw', 'SW'), ('frame_w', 'W'), ('frame_nw', 'NW'),
               ('frame_n', 'N'), ('frame_ne', 'NE'), ('frame_e', 'E'), ('frame_se', 'SE')]


def run(arguments, context):
    staging = Path(tempfile.mkdtemp())
    try:
        used = []
        for key, direction in _DIRECTIONS:
            if key in arguments:
                named = staging / f'{direction}.png'
                shutil.copyfile(context.input_path(arguments[key]), named)
                used.append(named)
        if not used:
            raise ValueError('Provide at least one frame')
        original = sys.argv
        try:
            sheet = context.output_path('sheet.png')
            gif = context.output_path('preview.gif')
            meta = context.output_path('meta.json')
            argv = ['pack_8dir', '--dir', str(staging), '--out', str(sheet),
                    '--json', str(meta), '--gif', str(gif), '--layout', arguments['layout'],
                    '--fps', str(arguments['fps']), '--pad', str(arguments['pad'])]
            sys.argv = argv
            context.progress(0.1, 'Packing 8-direction frames with existing Python skill')
            if implementation.main() != 0:
                raise ValueError('Direction packing failed')
        finally:
            sys.argv = original
        info = {}
        if meta.is_file():
            try:
                info = json.loads(meta.read_text('utf-8'))
            except ValueError:
                pass
        data = {'direction_count': len(info.get('order', [])),
                'frame_width': info.get('frameWidth', 0),
                'frame_height': info.get('frameHeight', 0), 'layout': arguments['layout']}
        return {'data': data, 'artifacts': [
            {'name': 'sheet.png', 'media_type': 'image/png'},
            {'name': 'preview.gif', 'media_type': 'image/gif'}]}
    finally:
        shutil.rmtree(staging, ignore_errors=True)
