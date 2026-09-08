"""JSON adapter for the existing green-to-shadow pass; no subprocess."""
import importlib.util
from pathlib import Path

import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location('green_to_shadow', Path(__file__).parent / 'scripts' / 'green_to_shadow_v2.py')
implementation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(implementation)


def run(arguments, context):
    source = context.input_path(arguments['input'])
    output = context.output_path('shadowed.png')
    context.progress(0.1, 'Converting chroma-green shadow with existing Python skill')
    implementation.green_to_shadow(str(source), str(output),
                                   max_alpha=arguments['max_alpha'],
                                   min_alpha=arguments['min_alpha'])
    from PIL import Image as _Image
    with _Image.open(source) as before, _Image.open(output) as after:
        changed = int(np.any(np.asarray(before.convert('RGBA')) != np.asarray(after.convert('RGBA')), axis=2).sum())
        width, height = before.size
    return {'data': {'green_pixels': changed, 'width': width, 'height': height},
            'artifacts': [{'name': 'shadowed.png', 'media_type': 'image/png'}]}
