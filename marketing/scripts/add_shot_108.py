"""1.0.8 の各ロケールの iPhone スクショ集合に E7（写真投稿）を追加し、先頭に並べ替える。"""
from asc import req
import os, hashlib, ssl, certifi, urllib.request, json
CTX = ssl.create_default_context(cafile=certifi.where())
VER = '063c3785-747c-4abc-b45b-4bdcffde0f73'
SRC = os.path.expanduser('~/Desktop/test/MapSNS/marketing/e_out')

def upload(set_id, path):
    data = open(path, 'rb').read()
    s, j = req('/v1/appScreenshots', 'POST', {'data': {'type': 'appScreenshots',
        'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})
    assert s == 201, (s, j)
    sid = j['data']['id']
    for op in j['data']['attributes']['uploadOperations']:
        chunk = data[op['offset']:op['offset'] + op['length']]
        r = urllib.request.Request(op['url'], data=chunk, method=op['method'],
                                   headers={h['name']: h['value'] for h in op['requestHeaders']})
        with urllib.request.urlopen(r, context=CTX) as resp: resp.read()
    s, j = req(f'/v1/appScreenshots/{sid}', 'PATCH', {'data': {'type': 'appScreenshots', 'id': sid,
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    assert s == 200, (s, j)
    return sid

s, j = req(f'/v1/appStoreVersions/{VER}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale&limit=10')
for l in j['data']:
    loc = l['attributes']['locale']; lang = {'ja': 'ja', 'en-US': 'en', 'ru': 'ru'}[loc]
    s2, j2 = req(f"/v1/appStoreVersionLocalizations/{l['id']}/appScreenshotSets?fields[appScreenshotSets]=screenshotDisplayType")
    sets = {x['attributes']['screenshotDisplayType']: x['id'] for x in j2['data']}
    sid = sets['APP_IPHONE_67']
    s3, j3 = req(f'/v1/appScreenshotSets/{sid}/appScreenshots?limit=20&fields[appScreenshots]=fileName')
    existing = [x['id'] for x in j3['data']]
    names = [x['attributes']['fileName'] for x in j3['data']]
    if any(n.startswith('E7_') for n in names):
        print(loc, 'E7 は既にある', names); continue
    new = upload(sid, f'{SRC}/E7_{lang}.png')
    order = [new] + existing
    s4, j4 = req(f'/v1/appScreenshotSets/{sid}/relationships/appScreenshots', 'PATCH',
                 {'data': [{'type': 'appScreenshots', 'id': i} for i in order]})
    print(loc, 'アップロード完了', len(order), '枚 / 並べ替え', s4)
