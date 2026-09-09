"""1.0.8 を審査に提出する。"""
from asc import req
import sys, json
APP='6749263650'; VER='063c3785-747c-4abc-b45b-4bdcffde0f73'
s,j=req(f'/v1/appStoreVersions/{VER}?fields[appStoreVersions]=versionString,appVersionState')
print('版:', j['data']['attributes'])
s,j=req(f'/v1/reviewSubmissions?filter[app]={APP}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW&limit=5')
subs=j.get('data',[])
if subs:
    sub=subs[0]; print('既存の提出を使用', sub['id'], sub['attributes']['state'])
else:
    s,j=req('/v1/reviewSubmissions','POST',{'data':{'type':'reviewSubmissions','attributes':{'platform':'IOS'},
        'relationships':{'app':{'data':{'type':'apps','id':APP}}}}})
    assert s==201,(s,json.dumps(j)[:500]); sub=j['data']; print('提出を作成', sub['id'])
sid=sub['id']
s,j=req(f'/v1/reviewSubmissions/{sid}/items?limit=20')
items=[i for i in j.get('data',[])]
print('現在の項目数', len(items))
if not items:
    s,j=req('/v1/reviewSubmissionItems','POST',{'data':{'type':'reviewSubmissionItems',
        'relationships':{'reviewSubmission':{'data':{'type':'reviewSubmissions','id':sid}},
                         'appStoreVersion':{'data':{'type':'appStoreVersions','id':VER}}}}})
    print('項目追加', s, '' if s==201 else json.dumps(j)[:400])
    assert s==201
s,j=req(f'/v1/reviewSubmissions/{sid}','PATCH',{'data':{'type':'reviewSubmissions','id':sid,'attributes':{'submitted':True}}})
print('提出', s, j['data']['attributes'] if s==200 else json.dumps(j)[:500])
