"""App Store 1.0.8 の版を作り、3言語の「今回のバージョンの変更点」を入れる。"""
from asc import req
from meta_108 import WHATS
import json, sys

APP = '6749263650'; VER = '1.0.8'

s, j = req(f'/v1/apps/{APP}/appStoreVersions?filter[versionString]={VER}&filter[platform]=IOS')
if j.get('data'):
    ver = j['data'][0]['id']; print('既存の版を使用', ver, j['data'][0]['attributes'].get('appVersionState'))
else:
    s, j = req('/v1/appStoreVersions', 'POST', {'data': {'type': 'appStoreVersions',
        'attributes': {'platform': 'IOS', 'versionString': VER},
        'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}})
    assert s == 201, (s, j)
    ver = j['data']['id']; print('版を作成', ver)

s, j = req(f'/v1/appStoreVersions/{ver}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew&limit=50')
locs = {l['attributes']['locale']: l['id'] for l in j['data']}
print('ロケール', sorted(locs))
for loc, text in WHATS.items():
    if loc not in locs:
        print('!! ロケール未作成:', loc); continue
    s, j = req(f'/v1/appStoreVersionLocalizations/{locs[loc]}', 'PATCH',
               {'data': {'type': 'appStoreVersionLocalizations', 'id': locs[loc],
                         'attributes': {'whatsNew': text}}})
    print(loc, 'whatsNew', s)
print('VERSION_ID', ver)
