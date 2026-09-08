"""JSON adapter for the existing CLI; arguments and filenames are backend-owned."""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('reduce_colors', Path(__file__).parent / 'scripts' / 'reduce_colors.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        sys.argv = ['reduce_colors', str(context.input_path(arguments['input'])),
                    str(context.output_path('reduced.png')), '--colors', str(arguments['colors']),
                    '--dither', arguments['dither']]
        context.progress(0.1, 'Reducing palette with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('Palette reduction failed')
    finally:
        sys.argv = original
    return {'data': {'colors': arguments['colors']},
            'artifacts': [{'name': 'reduced.png', 'media_type': 'image/png'}]}
