import re,sys,collections
f=sys.argv[1]
arm=None; runs=[]
cur=None
for l in open(f,errors='replace'):
    m=re.search(r'SIGK (\w+) p=(\w+) c=(\w+) k=(\d+)',l)
    if m:
        cur=dict(p=m[2],c=m[3],k=int(m[4]),R=[],E=[],F=[]); runs.append(cur); continue
    if cur is None: continue
    m=re.search(r'SIGR (.*)',l)
    if m: cur['R'].append(m[1].strip()); continue
    m=re.search(r'SIGE (.*)',l)
    if m: cur['E'].append(m[1].strip()); continue
    if 'named_version_crash:' in l and 'appears' in l: cur['F'].append(l)
for key in sorted({(r['p'],r['c']) for r in runs}):
    rs=[r for r in runs if (r['p'],r['c'])==key]
    W=[r for r in rs if any('"other line" appears 0' in x for x in r['F'])]
    oth=[r for r in rs if r['F'] and r not in W]
    print('== process',key[0],'control',key[1],'runs',len(rs),'W lost',len(W),'other-only failures',len(oth))
    ks=[r['k'] for r in W]
    if ks:
        g=[]; 
        for k in ks:
            if g and k==g[-1][1]+1: g[-1][1]=k
            else: g.append([k,k])
        print('  bands',g)
    def sig(r):
        a=[]
        for R,E in zip(r['R'],r['E']): a.append(re.sub(r'intents=\d+ ','',R)+' | '+E)
        return tuple(a) if a else ('no recovery with intents',)
    c=collections.Counter(sig(r) for r in W)
    for s,n in c.most_common(6):
        print('  ',n,'W-lost:'); [print('       ',x) for x in s]
    def traced(r): return any('outside=0' not in R and 'synced_w=true disk_w=false' in E and 'ver=0 owed=false' in E for R,E in zip(r['R'],r['E']))
    def anyset(L): return sum(1 for r in L if traced(r))
    notW=[r for r in rs if r not in W]
    print('   W-lost with the traced state:',anyset(W),'of',len(W),'| NOT-W-lost with it:',anyset(notW),'of',len(notW))
