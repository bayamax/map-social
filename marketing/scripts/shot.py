import subprocess, os, sys, time
# usage: shot.py <lang ja|en|ru> <warmup secs> <out.png> KEY=VAL ...   (launch app in locale, wait, screenshot)
lang=sys.argv[1]; warm=float(sys.argv[2]); out=sys.argv[3]
env=dict(os.environ)
for kv in sys.argv[4:]:
    k,v=kv.split('=',1); env['SIMCTL_CHILD_'+k]=v
DEV=os.environ.get('SHOT_DEV','E1426D77-194C-4B96-A49A-77B505206415')
loc={'ja':'ja_JP','en':'en_US','ru':'ru_RU'}[lang]
subprocess.run(['xcrun','simctl','terminate',DEV,'com.Threadplanet.MapSNS'],capture_output=True)
subprocess.Popen(['xcrun','simctl','launch',DEV,'com.Threadplanet.MapSNS','-AppleLanguages',f'({lang}, en)','-AppleLocale',loc],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(warm)
subprocess.run(['xcrun','simctl','io',DEV,'screenshot',out],capture_output=True)
print(out)
