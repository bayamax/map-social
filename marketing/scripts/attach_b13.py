"""build 13 を 1.0.8 に紐付け、暗号化申告を False にする。処理待ちがあれば再実行。"""
from asc import req
import sys
APP='6749263650'; VER_ID='063c3785-747c-4abc-b45b-4bdcffde0f73'; BUILD='13'
s,j=req(f'/v1/builds?filter[app]={APP}&filter[version]={BUILD}&limit=1&fields[builds]=version,processingState,usesNonExemptEncryption,uploadedDate')
if not j.get('data'):
    print('build 13 はまだ ASC に現れていません'); sys.exit(2)
b=j['data'][0]; a=b['attributes']
print('build', a['version'], a['processingState'], 'encryption=', a['usesNonExemptEncryption'], a.get('uploadedDate'))
if a['processingState'] != 'VALID':
    print('処理中'); sys.exit(3)
if a['usesNonExemptEncryption'] is None:
    s2,_=req(f"/v1/builds/{b['id']}", 'PATCH', {'data':{'type':'builds','id':b['id'],'attributes':{'usesNonExemptEncryption':False}}})
    print('暗号化申告 False に設定', s2)
s3,j3=req(f'/v1/appStoreVersions/{VER_ID}/relationships/build','PATCH',{'data':{'type':'builds','id':b['id']}})
print('紐付け', s3, j3 if s3>=400 else '')
s4,j4=req(f'/v1/appStoreVersions/{VER_ID}?fields[appStoreVersions]=versionString,appVersionState')
print(j4['data']['attributes'])
