"""JSON adapter for the existing frame-packing script; filenames are backend-owned."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('pack_frames', Path(__file__).parent / 'scripts' / 'pack_frames.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def _frame_paths(arguments, context):
    order = ['input', 'frame_2', 'frame_3', 'frame_4', 'frame_5',
             'frame_6', 'frame_7', 'frame_8']
    return [context.input_path(arguments[key]) for key in order if key in arguments]


def run(arguments, context):
    frames = _frame_paths(arguments, context)
    if not frames:
        raise ValueError('Provide at least one frame')
    original = sys.argv
    try:
        sheet = context.output_path('sheet.png')
        gif = context.output_path('preview.gif')
        meta = context.output_path('meta.json')
        argv = ['pack_frames', '--frames', *map(str, frames), '--out', str(sheet),
                '--json', str(meta), '--gif', str(gif), '--fps', str(arguments['fps']),
                '--anchor', arguments['anchor'], '--cols', str(arguments['cols']),
                '--pad', str(arguments['pad'])]
        sys.argv = argv
        context.progress(0.1, 'Packing frames with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('Frame packing failed')
    finally:
        sys.argv = original
    info = {}
    if meta.is_file():
        try:
            info = json.loads(meta.read_text('utf-8'))
        except ValueError:
            pass
    data = {'count': info.get('count', len(frames)), 'frame_width': info.get('frameWidth', 0),
            'frame_height': info.get('frameHeight', 0), 'cols': info.get('cols', 1),
            'rows': info.get('rows', 1), 'anchor': arguments['anchor']}
    return {'data': data, 'artifacts': [
        {'name': 'sheet.png', 'media_type': 'image/png'},
        {'name': 'preview.gif', 'media_type': 'image/gif'}]}
