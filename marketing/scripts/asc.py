import jwt, time, json, urllib.request, urllib.error, os, gzip, io, ssl, certifi
CTX = ssl.create_default_context(cafile=certifi.where())
HOME = os.path.expanduser('~/.appstoreconnect')
cfg = dict(l.strip().split('=',1) for l in open(HOME+'/credentials') if '=' in l)
KEY_ID = cfg['ASC_KEY_ID']; ISSUER = cfg['ASC_ISSUER_ID']
PRIV = open(HOME+'/private_keys/AuthKey_%s.p8' % KEY_ID).read()

def token():
    now = int(time.time())
    return jwt.encode({'iss': ISSUER, 'iat': now, 'exp': now+1200, 'aud': 'appstoreconnect-v1'},
                      PRIV, algorithm='ES256', headers={'kid': KEY_ID, 'typ': 'JWT'})

IND = cfg.get('ASC_IND_KEY_ID')
def token_ind():
    # Individual API key (Users and Access > Integrations > Individual Keys): no iss, sub=user
    now = int(time.time())
    priv = open(HOME+'/private_keys/AuthKey_%s.p8' % IND).read()
    return jwt.encode({'sub': 'user', 'iat': now, 'exp': now+1200, 'aud': 'appstoreconnect-v1'},
                      priv, algorithm='ES256', headers={'kid': IND, 'typ': 'JWT'})

def req(path, method='GET', body=None, raw_url=None, want_bytes=False, accept=None, ind=False):
    url = raw_url or ('https://api.appstoreconnect.apple.com' + path)
    h = {} if raw_url else {'Authorization': 'Bearer ' + (token_ind() if ind else token())}
    if accept: h['Accept'] = accept
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h['Content-Type'] = 'application/json'
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, context=CTX) as resp:
            b = resp.read()
            if want_bytes: return resp.status, b, dict(resp.headers)
            return resp.status, (json.loads(b) if b else None)
    except urllib.error.HTTPError as e:
        b = e.read()
        if want_bytes: return e.code, b, dict(e.headers)
        try: return e.code, json.loads(b)
        except: return e.code, b.decode(errors='replace')
