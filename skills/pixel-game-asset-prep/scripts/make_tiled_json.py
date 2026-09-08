#!/usr/bin/env python3
"""Generate a Tiled v1.10 JSON map from a full-scene PNG + a collision/object
config, using the 'single giant tile' trick (the whole image is one tile).

This is the reliable way to use AI-rendered scene images (which are NOT
tilesets) with tile-map renderers such as Bonfire's WorldMapByTiled.

CRITICAL LAYOUT RULE (learned the hard way — a '..' path makes the renderer
silently draw nothing, i.e. the player walks in a void):
  Put the output JSON and the map PNG in the SAME directory under the
  engine's image root (for Flame/Bonfire: assets/images/), and reference the
  image by bare filename. This script enforces it automatically.

Config file format (JSON, all rect coords NORMALIZED 0..1 fractions of the
image size — measure them against the labeled original, then they survive
any resize):
{
  "collisions": [[x, y, w, h], ...],
  "doors":   [{"rect": [x,y,w,h], "targetZone": "town", "targetSpawn": "from_shop", "requiredLevel": 3}],
  "spawns":  [{"name": "default", "at": [x, y]}],
  "npcs":    [{"npcId": "clerk", "at": [x, y]}]
}

Usage:
  python3 make_tiled_json.py --name town --image map_town.png --config town_config.json --out tiles/town.json
The --out directory must be the same directory the game loads <name>.png from.
"""
import argparse
import json
import os

from PIL import Image


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--name', required=True)
    p.add_argument('--image', required=True, help='map PNG (used for size + tileset reference)')
    p.add_argument('--config', required=True)
    p.add_argument('--out', required=True)
    args = p.parse_args()

    W, H = Image.open(args.image).size
    cfg = json.load(open(args.config))
    img_file = os.path.basename(args.image)
    out_dir = os.path.dirname(os.path.abspath(args.out))
    same_dir = os.path.dirname(os.path.abspath(args.image)) == out_dir
    if not same_dir:
        print(f'[warn] image and output JSON are in different directories; '
              f'ensure the engine can resolve {img_file} relative to the JSON')

    objs, i = [], 1

    def nxt():
        nonlocal i
        i += 1
        return i - 1

    collisions = []
    for x, y, w, h in cfg.get('collisions', []):
        collisions.append({'id': nxt(), 'name': '', 'type': 'collision', 'rotation': 0,
                           'x': round(x * W), 'y': round(y * H),
                           'width': round(w * W), 'height': round(h * H),
                           'visible': True, 'properties': []})
    for d in cfg.get('doors', []):
        x, y, w, h = d['rect']
        objs.append({'id': nxt(), 'name': '', 'type': 'door', 'rotation': 0,
                     'x': round(x * W), 'y': round(y * H),
                     'width': round(w * W), 'height': round(h * H), 'visible': True,
                     'properties': [
                         {'name': 'targetZone', 'type': 'string', 'value': d['targetZone']},
                         {'name': 'targetSpawn', 'type': 'string', 'value': d.get('targetSpawn', 'default')},
                         {'name': 'requiredLevel', 'type': 'string', 'value': str(d.get('requiredLevel', 1))}]})
    for s in cfg.get('spawns', []):
        objs.append({'id': nxt(), 'name': s['name'], 'type': 'spawn', 'rotation': 0,
                     'x': round(s['at'][0] * W), 'y': round(s['at'][1] * H),
                     'width': 8, 'height': 8, 'visible': True, 'properties': []})
    for n in cfg.get('npcs', []):
        objs.append({'id': nxt(), 'name': '', 'type': 'npc', 'rotation': 0,
                     'x': round(n['at'][0] * W), 'y': round(n['at'][1] * H),
                     'width': 8, 'height': 8, 'visible': True,
                     'properties': [{'name': 'npcId', 'type': 'string', 'value': n['npcId']}]})

    doc = {
        'compressionlevel': -1, 'height': 1, 'infinite': False,
        'nextlayerid': 4, 'nextobjectid': i,
        'orientation': 'orthogonal', 'renderorder': 'right-down',
        'tiledversion': '1.10.2', 'tileheight': H, 'tilewidth': W,
        'type': 'map', 'version': '1.10', 'width': 1,
        'tilesets': [{'firstgid': 1, 'columns': 1, 'image': img_file,
                      'imageheight': H, 'imagewidth': W, 'margin': 0,
                      'name': args.name, 'spacing': 0, 'tilecount': 1,
                      'tileheight': H, 'tilewidth': W}],
        'layers': [
            {'data': [1], 'height': 1, 'id': 1, 'name': 'background',
             'opacity': 1, 'type': 'tilelayer', 'visible': True, 'width': 1, 'x': 0, 'y': 0},
            {'draworder': 'topdown', 'id': 2, 'name': 'collisions',
             'objects': collisions, 'opacity': 1, 'type': 'objectgroup', 'visible': True, 'x': 0, 'y': 0},
            {'draworder': 'topdown', 'id': 3, 'name': 'objects',
             'objects': objs, 'opacity': 1, 'type': 'objectgroup', 'visible': True, 'x': 0, 'y': 0}],
    }
    with open(args.out, 'w') as f:
        json.dump(doc, f)
    json.load(open(args.out))  # validate

    # Deterministic guards (these bugs are silent in-game):
    # 1. spawn inside a door rect -> instant zone bounce.
    # 2. spawn inside a collision rect -> soft-lock.
    def inside(px, py, r):
        return r['x'] <= px <= r['x'] + r['width'] and r['y'] <= py <= r['y'] + r['height']

    for o in objs:
        if o['type'] == 'spawn':
            for d in [x for x in objs if x['type'] == 'door']:
                # player hitbox is at the feet: check a 56x30 box under the point
                if inside(o['x'], o['y'] + 28, d) or inside(o['x'], o['y'], d):
                    print(f"[warn] spawn '{o['name']}' may overlap door rect "
                          f"({d['x']},{d['y']},{d['width']}x{d['height']}) -> zone bounce risk")
            for c in collisions:
                if inside(o['x'], o['y'] + 28, c):
                    print(f"[warn] spawn '{o['name']}' feet inside collision rect "
                          f"({c['x']},{c['y']},{c['width']}x{c['height']}) -> soft-lock risk")
    print(f'[done] {args.out}: {len(collisions)} collisions, {len(objs)} objects, tile {W}x{H}')


if __name__ == '__main__':
    main()
