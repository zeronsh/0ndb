import re,collections,sys
d=collections.defaultdict(list)
for l in open(sys.argv[1],errors='replace'):
    m=re.match(r'step_replay: step: Step_Arm\{process = (\w+), held = (\w+)\} k=(\d+): (.*)',l)
    if m: d[(m[1],m[2],m[4].strip())].append(int(m[3]))
    elif 'points=' in l: print(l.strip())
def bands(ks):
    g=[]
    for k in sorted(ks):
        if g and k==g[-1][1]+1: g[-1][1]=k
        else: g.append([k,k])
    return g
for k,v in sorted(d.items(),key=lambda x:(x[0][0],x[0][1],-len(x[1]))):
    if k[0]=='true' and len(sys.argv)<3: continue
    print(len(v),'process',k[0],'held',k[1],k[2][:220]); print('    ',bands(v)[:8])
