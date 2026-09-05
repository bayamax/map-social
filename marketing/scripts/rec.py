import subprocess, os, sys, time, signal
# usage: rec.py <lang> <start secs> <duration secs> <out.mov> KEY=VAL ...   (launch app, wait, record video)
lang=sys.argv[1]; start=float(sys.argv[2]); dur=float(sys.argv[3]); out=sys.argv[4]
env=dict(os.environ)
for kv in sys.argv[5:]:
    k,v=kv.split('=',1); env['SIMCTL_CHILD_'+k]=v
DEV=os.environ.get('SHOT_DEV','E1426D77-194C-4B96-A49A-77B505206415')
loc={'ja':'ja_JP','en':'en_US','ru':'ru_RU'}[lang]
subprocess.run(['xcrun','simctl','terminate',DEV,'com.Threadplanet.MapSNS'],capture_output=True)
subprocess.Popen(['xcrun','simctl','launch',DEV,'com.Threadplanet.MapSNS','-AppleLanguages',f'({lang}, en)','-AppleLocale',loc],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(start)
rec=subprocess.Popen(['xcrun','simctl','io',DEV,'recordVideo','--codec','h264','--force',out],stderr=subprocess.PIPE)
time.sleep(dur)
rec.send_signal(signal.SIGINT)
rec.wait(timeout=60)
print(out, os.path.getsize(out))
