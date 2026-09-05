# build 12 が処理完了したら 1.0.7 に紐付ける（提出はしない）
import sys, time
sys.path.insert(0, '/private/tmp/claude-501/-Users-oobayashikoushin--claude-projects--Users-oobayashikoushin/228c6563-f55a-4346-92dc-129ef7f204c0/scratchpad')
from asc import req
VER = '48586e47-7e54-4f1a-98e6-12440c83c551'
s, b = req('/v1/builds?filter[app]=6749263650&filter[version]=12&fields[builds]=version,processingState,usesNonExemptEncryption')
if not b['data']:
    print('build 12: not uploaded yet'); sys.exit(2)
d = b['data'][0]; print('build 12:', d['id'], d['attributes'])
if d['attributes']['processingState'] != 'VALID':
    sys.exit(3)
s, cur = req(f'/v1/appStoreVersions/{VER}/build')
if cur and cur.get('data') and cur['data']['id'] == d['id']:
    print('already attached'); sys.exit(0)
s, r = req(f'/v1/appStoreVersions/{VER}/relationships/build', 'PATCH', {'data': {'type': 'builds', 'id': d['id']}})
print('attach status', s)
s, v = req(f'/v1/appStoreVersions/{VER}?fields[appStoreVersions]=versionString,appStoreState,appVersionState')
print(v['data']['attributes'])
