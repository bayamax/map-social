import subprocess, sys, os
FF='/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1'
src=sys.argv[1]; out=sys.argv[2]
segs=[tuple(map(float,s.split('-'))) for s in sys.argv[3].split(',')]   # "0-6,13-21,30-33,44.5-50.5"
XF=0.6
# 1) 各セグメントを固定30fps・886x1920 の中間ファイルへ
parts=[]
for i,(a,b) in enumerate(segs):
    p=f'vid/_seg{i}.mp4'; parts.append(p)
    subprocess.run([FF,'-hide_banner','-loglevel','error','-y','-ss',str(a),'-to',str(b),'-i',src,
        '-vf','scale=886:-2,crop=886:1920,fps=30,format=yuv420p','-fps_mode','cfr','-r','30',
        '-c:v','h264_videotoolbox','-b:v','12M','-an',p],check=True)
# 2) クロスフェードで連結 + 無音AAC
cmd=[FF,'-hide_banner','-loglevel','error','-y']
for p in parts: cmd+=['-i',p]
cmd+=['-f','lavfi','-i','anullsrc=r=44100:cl=stereo']
n=len(parts); fc=[]; durs=[b-a for a,b in segs]; prev='0:v'; off=0
for i in range(1,n):
    off+=durs[i-1]-XF
    o=f'[x{i}]' if i<n-1 else '[vout]'
    fc.append(f'[{prev}][{i}:v]xfade=transition=fade:duration={XF}:offset={off:.3f}{o}'); prev=o.strip('[]')
total=sum(durs)-XF*(n-1)
cmd+=['-filter_complex',';'.join(fc),'-map','[vout]','-map',f'{n}:a','-t',f'{total:.2f}','-c:v','h264_videotoolbox','-profile:v','high','-pix_fmt','yuv420p','-b:v','8M','-r','30','-c:a','aac','-b:a','128k','-movflags','+faststart',out]
subprocess.run(cmd,check=True); print(out,'%.1fs'%total)
