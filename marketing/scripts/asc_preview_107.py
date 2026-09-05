# 1.0.7 の ja/en-US/ru に iPhone 6.7" App Preview 動画をアップロード（既存のプレビューがあれば置き換え）
import os, sys, json, hashlib, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import req, CTX
locs = json.load(open('ads/v107_state.json'))['locs']
FILES = {'ja': 'vid/preview_ja.mp4', 'en-US': 'vid/preview_en.mp4', 'ru': 'vid/preview_ru.mp4'}
POSTER = '00:00:13:00'   # 羽田3Dのカット
out = {}
for loc, lid in locs.items():
    path = FILES[loc]; data = open(path, 'rb').read()
    s, k = req(f'/v1/appStoreVersionLocalizations/{lid}/appPreviewSets?fields[appPreviewSets]=previewType')
    sets = {x['attributes']['previewType']: x['id'] for x in k['data']}
    if 'IPHONE_67' not in sets:
        s, j = req('/v1/appPreviewSets', 'POST', {'data': {'type': 'appPreviewSets', 'attributes': {'previewType': 'IPHONE_67'},
                   'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': lid}}}}})
        assert s == 201, (s, j); sets['IPHONE_67'] = j['data']['id']
    set_id = sets['IPHONE_67']
    s, j = req(f'/v1/appPreviewSets/{set_id}/appPreviews?fields[appPreviews]=fileName&limit=10')
    for x in j['data']:
        s2, _ = req(f"/v1/appPreviews/{x['id']}", 'DELETE'); print('  del', x['attributes']['fileName'], s2)
    s, j = req('/v1/appPreviews', 'POST', {'data': {'type': 'appPreviews', 'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data),
               'mimeType': 'video/mp4', 'previewFrameTimeCode': POSTER},
               'relationships': {'appPreviewSet': {'data': {'type': 'appPreviewSets', 'id': set_id}}}}})
    assert s == 201, (s, j)
    pid = j['data']['id']
    for op in j['data']['attributes']['uploadOperations']:
        chunk = data[op['offset']:op['offset'] + op['length']]
        r = urllib.request.Request(op['url'], data=chunk, method=op['method'], headers={h['name']: h['value'] for h in op['requestHeaders']})
        with urllib.request.urlopen(r, context=CTX) as resp: resp.read()
    s, j = req(f'/v1/appPreviews/{pid}', 'PATCH', {'data': {'type': 'appPreviews', 'id': pid, 'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest(), 'previewFrameTimeCode': POSTER}}})
    assert s == 200, (s, j)
    print(loc, 'uploaded', pid, len(data))
    out[loc] = pid
json.dump(out, open('vid/preview_ids.json', 'w'))
