import re,collections,sys
pts=collections.OrderedDict()
for l in open(sys.argv[1],errors='replace'):
    m=re.match(r'tree_fault: (\w+) read (\d+): (.*)',l)
    if m: pts.setdefault((m[1],int(m[2])),[]).append(m[3].strip())
cat=collections.Counter(); ex={}
for (op,n),fs in pts.items():
    ks=set()
    for f in fs:
        g=re.search(r'failed once \[[^\]]*\]: ([a-z ]+): n(\d) (DISK|TREE) misses (\d+)',f)
        k=f'{g[1]}: n{g[2]} {g[3]} misses {g[4]}' if g else re.sub(r'\d+','N',re.sub(r'[0-9a-f]{8}','H',re.sub(r'^.*failed once \[[^\]]*\]: ','',f)))[:80]
        ks.add(k); ex.setdefault((op,k),(n,f[:300]))
    for k in ks: cat[(op,k)]+=1
for k,v in sorted(cat.items()): print(v,k[0],'|',k[1],'| first',ex[k][0])
