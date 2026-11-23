import re,os,sys
root=sys.argv[1]
dirs=sys.argv[2].split(',') if len(sys.argv)>2 else ['src']
files=[]
for sub in dirs:
  for d,_,fs in os.walk(root+'/'+sub):
    for f in fs:
        if f.endswith('.odin'): files.append(os.path.join(d,f))
allsrc=[]
for d,_,fs in os.walk(root+'/src'):
    for f in fs:
        if f.endswith('.odin'): allsrc.append(os.path.join(d,f))
src={f:open(f).read() for f in set(files)|set(allsrc)}
scan=set(files)
structs={}
st_re=re.compile(r'(?m)^([A-Z]\w*)\s*::\s*struct[^{]*\{')
for f,s in src.items():
    for m in st_re.finditer(s):
        name=m.group(1); i=m.end(); depth=1; j=i
        while j<len(s) and depth>0:
            if s[j]=='{': depth+=1
            elif s[j]=='}': depth-=1
            j+=1
        body=s[i:j-1]
        fields=structs.setdefault((os.path.dirname(f),name),{})
        structs.setdefault(name,{}).update({k:v for k,v in fields.items()})
        for fm in re.finditer(r'(?m)^\s*([A-Za-z_][\w, ]*?)\s*:\s*([^\n]+?)\s*,?\s*$',body):
            t=fm.group(2).strip().rstrip(',')
            for n in fm.group(1).split(','):
                fields[n.strip()]=t
        structs.setdefault(name,{}).update(fields)
def base_type(t):
    t=t.strip()
    t=re.sub(r'^\^','',t)
    m=re.match(r'([A-Za-z_][\w.]*)',t)
    if not m: return None
    n=m.group(1).split('.')[-1]
    return n
def is_map(t): return bool(re.match(r'\^?map\[',t.strip()))
loop=re.compile(r'^(\s*)for\s+([^{]*?)\s+in\s+(&?)([A-Za-z_][\w.\[\]^]*)\s*\{', re.M)
proc_re=re.compile(r'(?m)^\s*([A-Za-z_]\w*)\s*::\s*proc[^(]*\(([^)]*)\)')
side=re.compile(r'\b(prim|odb|omap|journal|pack|osync|fs|crdt|fstree|obj|search|textdiff|http|sync|thread)\.\w+\(|\b(_?[a-z][a-z0-9_]*)\s*\(')
pure=set('len cap min max abs delete delete_key clear make new free string transmute cast auto_cast size_of align_of raw_data resize reserve inject_at ordered_remove unordered_remove copy slice contains has_prefix has_suffix compare clone_string'.split())
out=[];total=0
for f,s in sorted(src.items()):
    if f not in scan: continue
    procs=[(m.start(),m.group(2)) for m in proc_re.finditer(s)]
    here=os.path.dirname(f)
    for m in loop.finditer(s):
        expr=m.group(4)
        if '_sorted' in expr or 'sorted_' in expr or 'unordered(' in expr: continue
        parts=expr.split('.')
        pp=[p for p in procs if p[0]<m.start()]
        sig=pp[-1][1] if pp else ''
        seg=s[pp[-1][0] if pp else 0:m.start()]
        def local_type(n):
            sm=re.search(r'\b'+re.escape(n)+r'\s*:\s*([^,=]+)',sig)
            if sm: return sm.group(1)
            dm=list(re.finditer(r'(?m)^\s*'+re.escape(n)+r'\s*:\s*([^=\n]+?)(\s*=|$)',seg))
            if dm: return dm[-1].group(1)
            dm=list(re.finditer(r'\b'+re.escape(n)+r'\s*:=\s*(make\((map\[[^\n]*)|new\((\w+)|&?(\w+)\{)',seg))
            if dm:
                g=dm[-1]
                if g.group(2): return g.group(2)
                if g.group(3): return g.group(3)
                if g.group(4): return g.group(4)
            return None
        def resolve(chain, depth=0):
            t=local_type(chain[0].lstrip('&^'))
            if t is None and depth<3:
                am=list(re.finditer(r'\b'+re.escape(chain[0])+r'\s*:=\s*&?([A-Za-z_][\w.]*)\s*$',seg,re.M))
                if am:
                    sub=am[-1].group(1).split('.')
                    if len(sub)>1:
                        t=resolve(sub,depth+1)
            if t is None: return None
            for fld in chain[1:]:
                fld=fld.split('[')[0]
                st=base_type(t)
                sd=structs.get((here,st)) or structs.get(st)
                if sd is None or fld not in sd:
                    return None
                t=sd[fld]
            return t
        t=local_type(parts[0].lstrip('&^'))
        if t is None and len(parts)>=1:
            rt=resolve(parts[:1])
            if rt is not None: t=rt
        ok=t is not None
        for fld in parts[1:]:
            if not ok: break
            fld=fld.split('[')[0]
            st=base_type(t)
            sd=structs.get((here,st)) or structs.get(st)
            if sd is None or fld not in sd:
                ok=False; break
            t=sd[fld]
        if ok and parts[-1].endswith(']') and is_map(t):
            mm=re.match(r'\^?map\[[^\]]*\](.*)',t.strip())
            t=mm.group(1) if mm else t
        if not ok or not is_map(t): continue
        total+=1
        start=m.end(); depth=1; i=start
        while i<len(s) and depth>0:
            if s[i]=='{': depth+=1
            elif s[i]=='}': depth-=1
            i+=1
        body=s[start:i-1]
        calls=sorted(set(x.group(0).rstrip('(').strip() for x in side.finditer(body) if x.group(0).rstrip('(').strip().split('.')[-1] not in pure))
        ret=bool(re.search(r'\breturn\b|\bbreak\b|or_return',body))
        idxw=bool(re.search(r'\w+\[[^\]]+\]\s*=[^=]',body))
        if os.environ.get('PURE'):
            if not calls and not ret:
                out.append(("IDXW" if idxw else "PURE", f.replace(root+'/',''), s[:m.start()].count('\n')+1, m.group(2).strip(), m.group(3)+expr, t.strip(), []))
            continue
        if calls or ret or idxw:
            out.append(("SIDE" if calls else "EARLY", f.replace(root+'/',''), s[:m.start()].count('\n')+1, m.group(2).strip(), m.group(3)+expr, t.strip(), calls))
import json
if os.environ.get('JSON'):
    print(json.dumps(out))
else:
    for o in out: print("%-5s %s:%d  for %s in %s  [%s] %s"%(o[0],o[1],o[2],o[3],o[4],o[5][:30],' '.join(o[6][:8])))
print("resolved map loops",total,"flagged",len(out),file=sys.stderr)
if os.environ.get('CHECK'):
    sys.exit(1 if out else 0)
