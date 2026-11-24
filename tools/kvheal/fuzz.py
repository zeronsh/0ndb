import subprocess,random,shutil,os,sys
D='/home/user/gates/kvheal/fz'; src='/home/user/gates/kvheal/fzsrc'; B='/home/user/gates/bin/'
for d in (D,src): shutil.rmtree(d,ignore_errors=True)
os.makedirs(src); subprocess.run([B+'kh-base','fill',src],capture_output=True,timeout=20); subprocess.run([B+'kh-base','count',src],capture_output=True,timeout=20)
orig=open(src+'/state.0.log','rb').read(); r=random.Random(7); bad=0; worse=0; mn=200; hist={}
for t in range(400):
    shutil.rmtree(D,ignore_errors=True); shutil.copytree(src,D); b=bytearray(orig)
    for _ in range(r.choice((1,1,2,3))):
        i=r.randrange(16,len(b)); k=r.choice(('flip','run','zero'))
        if k=='flip': b[i]^=1<<r.randrange(8)
        else:
            for j in range(i,min(len(b),i+r.randrange(1,60))): b[j]=0 if k=='zero' else r.randrange(256)
    open(D+'/state.0.log','wb').write(b)
    res={}
    for w in ('base','fix'):
        D2=D+w; shutil.rmtree(D2,ignore_errors=True); shutil.copytree(D,D2); os.remove(D2+'/state.0.idx')
        p=subprocess.run([B+'kh-'+w,'count',D2],capture_output=True,timeout=20)
        o=p.stdout.decode(); res[w]=int(o.split('count: ')[1].split()[0]) if 'count: ' in o else -1
    if res['fix']<0: bad+=1; print('CRASH/open error',t,p.stdout[:100],p.stderr[:120])
    elif res['fix']<res['base']: worse+=1; print('WORSE',t,res)
    mn=min(mn,res['fix']); hist[res['base']//50*50]=hist.get(res['base']//50*50,0)+1
print('400 random damages: fix crashed/failed',bad,'| fix read fewer than base',worse,'| fix minimum',mn,'| base buckets',sorted(hist.items()))
