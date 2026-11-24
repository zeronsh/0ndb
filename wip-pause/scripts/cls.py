import re,sys,collections
runs=[];cur=None
for l in open(sys.argv[1],errors='replace'):
    m=re.search(r'SIGK (\w+) p=(\w+) c=(\w+) k=(\d+)',l)
    if m: cur=dict(p=m[2],c=m[3],k=int(m[4]),F=[],P=None,E=None); runs.append(cur); continue
    if cur is None: continue
    if 'SIGP' in l: cur['P']=l.split('SIGP ')[1].strip()
    elif 'SIGF' in l: cur['E']=(cur.get('L') or '')+' '+l.split('SIGF ')[1].strip()
    elif 'SIGL' in l: cur['L']=l.split('SIGL ')[1].strip()
    elif 'appears' in l and 'named_version_crash:' in l: cur['F'].append(re.search(r'"([^"]+)" appears (\d+) times in a.txt on (\w+)',l).groups())
def bands(ks):
    g=[]
    for k in ks:
        if g and k==g[-1][1]+1: g[-1][1]=k
        else: g.append([k,k])
    return g
for key in sorted({(r['p'],r['c']) for r in runs}):
    rs=[r for r in runs if (r['p'],r['c'])==key]
    print('== process',key[0],'control',key[1],'runs',len(rs))
    c=collections.defaultdict(list)
    for r in rs:
        e=r['E'] or ''
        e=re.sub(r'k=\d+ ','',e)
        c[(tuple(sorted(r['F'])),r['P'],e)].append(r['k'])
    for k,v in sorted(c.items(),key=lambda x:-len(x[1])):
        b=bands(v)
        print(' ',len(v),'fail' if k[0] else 'ok  ',k[0],'\n      pre:',k[1],'\n      end:',k[2],'\n      bands:',b[:6],'...' if len(b)>6 else '')
