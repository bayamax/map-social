"""Create App Store version 1.0.7, ru localization, metadata, screenshots. Resumable via ads/v107_state.json."""
from asc import req
import json, os, sys, hashlib, time, urllib.request, ssl, certifi
from meta_107 import DESC, WHATS, KEYWORDS, NAME, SUBTITLE
APP = '6749263650'; VER = '1.0.7'
STATE = 'ads/v107_state.json'
state = json.load(open(STATE)) if os.path.exists(STATE) else {}
def save(): json.dump(state, open(STATE, 'w'), indent=1, ensure_ascii=False)
CTX = ssl.create_default_context(cafile=certifi.where())

# 1) version
if 'ver' not in state:
    s, j = req(f'/v1/apps/{APP}/appStoreVersions?filter[versionString]={VER}&filter[platform]=IOS')
    if j.get('data'):
        state['ver'] = j['data'][0]['id']
    else:
        s, j = req('/v1/appStoreVersions', 'POST', {'data': {'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': VER},
                   'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}})
        assert s == 201, (s, j); state['ver'] = j['data']['id']
    save()
ver = state['ver']; print('version', ver)

# 2) localizations
s, j = req(f'/v1/appStoreVersions/{ver}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale')
locs = {l['attributes']['locale']: l['id'] for l in j['data']}
if 'ru' not in locs:
    s, j = req('/v1/appStoreVersionLocalizations', 'POST', {'data': {'type': 'appStoreVersionLocalizations', 'attributes': {'locale': 'ru'},
               'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': ver}}}}})
    assert s == 201, (s, j); locs['ru'] = j['data']['id']
print('locs', locs); state['locs'] = locs; save()

# 3) metadata
for loc, lid in locs.items():
    if loc not in DESC: continue
    attrs = {'description': DESC[loc], 'whatsNew': WHATS[loc], 'keywords': KEYWORDS[loc]}
    if loc == 'ru': attrs['supportUrl'] = 'https://sites.google.com/view/mapsosial/%E3%83%9B%E3%83%BC%E3%83%A0'
    s, j = req(f'/v1/appStoreVersionLocalizations/{lid}', 'PATCH', {'data': {'type': 'appStoreVersionLocalizations', 'id': lid, 'attributes': attrs}})
    print('meta', loc, s, '' if s == 200 else json.dumps(j)[:400])

# 4) app info (name/subtitle) for ru
s, j = req(f'/v1/apps/{APP}/appInfos?fields[appInfos]=appStoreState,state')
infos = j['data']; print('appInfos', [(a['id'], a['attributes']) for a in infos])
editable = [a for a in infos if a['attributes'].get('state') not in ('READY_FOR_DISTRIBUTION',)] or infos
info = editable[0]['id']
s, k = req(f'/v1/appInfos/{info}/appInfoLocalizations?fields[appInfoLocalizations]=locale,name,subtitle')
il = {x['attributes']['locale']: x['id'] for x in k['data']}
if 'ru' not in il:
    s, j = req('/v1/appInfoLocalizations', 'POST', {'data': {'type': 'appInfoLocalizations', 'attributes': {'locale': 'ru', 'name': NAME['ru'], 'subtitle': SUBTITLE['ru']},
               'relationships': {'appInfo': {'data': {'type': 'appInfos', 'id': info}}}}})
    print('appInfoLoc ru', s, json.dumps(j)[:400])
else:
    s, j = req(f"/v1/appInfoLocalizations/{il['ru']}", 'PATCH', {'data': {'type': 'appInfoLocalizations', 'id': il['ru'], 'attributes': {'name': NAME['ru'], 'subtitle': SUBTITLE['ru']}}})
    print('appInfoLoc ru patch', s, json.dumps(j)[:300])

# 5) screenshots
def upload_screenshot(set_id, path):
    data = open(path, 'rb').read()
    s, j = req('/v1/appScreenshots', 'POST', {'data': {'type': 'appScreenshots', 'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
               'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})
    assert s == 201, (s, j)
    sid = j['data']['id']
    for op in j['data']['attributes']['uploadOperations']:
        chunk = data[op['offset']:op['offset'] + op['length']]
        r = urllib.request.Request(op['url'], data=chunk, method=op['method'], headers={h['name']: h['value'] for h in op['requestHeaders']})
        with urllib.request.urlopen(r, context=CTX) as resp: resp.read()
    s, j = req(f'/v1/appScreenshots/{sid}', 'PATCH', {'data': {'type': 'appScreenshots', 'id': sid, 'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    assert s == 200, (s, j)
    return sid

FILES = {'APP_IPHONE_67': lambda lang: [f'ads/e_out/E{n}_{lang}.png' for n in range(1, 7)],
         'APP_IPAD_PRO_3GEN_129': lambda lang: [f'ads/e_out/P{n}_{lang}.png' for n in (1, 2)]}
state.setdefault('shots', {})
for loc, lid in locs.items():
    lang = {'ja': 'ja', 'en-US': 'en', 'ru': 'ru'}[loc]
    s, k = req(f'/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?fields[appScreenshotSets]=screenshotDisplayType')
    sets = {x['attributes']['screenshotDisplayType']: x['id'] for x in k['data']}
    for dt, files in FILES.items():
        key = f'{loc}/{dt}'
        if key in state['shots']: print('done', key); continue
        if dt not in sets:
            s, j = req('/v1/appScreenshotSets', 'POST', {'data': {'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': dt},
                       'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': lid}}}}})
            assert s == 201, (s, j); sets[dt] = j['data']['id']
        set_id = sets[dt]
        # remove existing (copied from previous version)
        s, j = req(f'/v1/appScreenshotSets/{set_id}/appScreenshots?fields[appScreenshots]=fileName&limit=50')
        for x in j['data']:
            s2, _ = req(f"/v1/appScreenshots/{x['id']}", 'DELETE'); print('  del', x['attributes']['fileName'], s2)
        ids = []
        for p in files(lang):
            ids.append(upload_screenshot(set_id, p)); print('  up', p)
        state['shots'][key] = ids; save()
print('screenshots done')
