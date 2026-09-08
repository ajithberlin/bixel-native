"""JSON adapter for the existing CLI; arguments and filenames are backend-owned."""
import importlib.util
from pathlib import Path
import sys

import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location('remove_bg', Path(__file__).parent / 'scripts' / 'remove_bg.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def _removed_percent(input_path, output_path):
    """Share of formerly-opaque pixels that became transparent (0–100)."""
    with Image.open(input_path) as source:
        before = np.asarray(source.convert('RGBA'))[..., 3] > 0
    with Image.open(output_path) as output:
        after = np.asarray(output.convert('RGBA'))[..., 3] > 0
    opaque = int(before.sum())
    if not opaque:
        return 0.0
    return round(100.0 * int((before & ~after).sum()) / opaque, 1)


def run(arguments, context):
    original = sys.argv
    try:
        from_path = context.input_path(arguments['input'])
        output = context.output_path('clean.png')
        argv = ['remove_bg', str(from_path), str(output),
                '--mode', arguments['mode'], '--color', arguments['color'],
                '--tolerance', str(arguments['tolerance'])]
        if arguments['despill']:
            argv.append('--despill')
        if arguments['feather'] > 0:
            argv += ['--feather', str(arguments['feather'])]
        sys.argv = argv
        context.progress(0.1, 'Removing background with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('Background removal failed')
    finally:
        sys.argv = original
    data = {'mode': arguments['mode'], 'color': arguments['color'],
            'removed_percent': _removed_percent(from_path, output)}
    return {'data': data,
            'artifacts': [{'name': 'clean.png', 'media_type': 'image/png'}]}
