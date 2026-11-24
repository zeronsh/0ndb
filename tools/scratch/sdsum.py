import re,collections,sys
pend=[]
for l in open(sys.argv[1],errors='replace'):
    if not l.startswith('shadow_damage:'): continue
    m=re.match(r'shadow_damage: (\w+), (\w+): (\d+) failures',l)
    if m:
        c=collections.OrderedDict(); ex={}
        for p in pend:
            if 'the edited text is in' in p: print('    ',p[15:200].strip()); continue
            k='mount-open check' if 'mount open:' in p else 'mount check' if ' mount: ' in p else (re.search(r': (DISK|TREE d\d lists|TREE|LIST|REBORN|REMOUNT|DOWN|AFTER|CONTROL)',p) or [None,'other'])[1]
            k=re.sub(r'd\d','dN',k); c[k]=c.get(k,0)+1; ex.setdefault(k,p[15:200].strip())
        print(m[1],m[2],m[3],dict(c))
        for k in ex:
            if 'check' not in k: print('    ',ex[k])
        pend=[]
    else: pend.append(l)
