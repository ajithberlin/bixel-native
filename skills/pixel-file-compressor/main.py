"""JSON adapter for the existing CLI; arguments and filenames are backend-owned."""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('compress_asset', Path(__file__).parent / 'scripts' / 'compress_asset.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    original = sys.argv
    try:
        source = context.input_path(arguments['input'])
        output = context.output_path('compressed.png')
        argv = ['compress_asset', str(source), '--out', str(output),
                '--colors', str(arguments['colors']), '--scale', str(arguments['scale']),
                '--format', 'png', '--quality', str(arguments['quality'])]
        if arguments['pixel_art']:
            argv.append('--pixel-art')
        if arguments['lossless']:
            argv.append('--lossless')
        sys.argv = argv
        context.progress(0.1, 'Compressing asset with existing Python skill')
        if implementation.main() != 0:
            raise ValueError('Compression failed')
    finally:
        sys.argv = original
    in_bytes = source.stat().st_size
    out_bytes = output.stat().st_size
    data = {'input_bytes': in_bytes, 'output_bytes': out_bytes,
            'saved_percent': round(100.0 * (1 - out_bytes / max(in_bytes, 1)), 1)}
    return {'data': data,
            'artifacts': [{'name': 'compressed.png', 'media_type': 'image/png'}]}
