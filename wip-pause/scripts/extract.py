import json,sys
out=None
def walk(x):
    global out
    if out: return
    if isinstance(x,str):
        if 'NV_ROOT :: ' in x and '```odin\npackage sim' in x: out=x.split('```odin\n',1)[1].split('\n```',1)[0]
    elif isinstance(x,dict):
        for v in x.values(): walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
for l in open(sys.argv[1]):
    if 'NV_ROOT :: ' in l and 'package sim' in l: walk(json.loads(l))
    if out: break
open(sys.argv[2],'w').write(out+'\n') if out else sys.exit('not found')
