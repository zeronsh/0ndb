import sys,struct
mode,p=sys.argv[1],sys.argv[2]
b=bytearray(open(p,'rb').read())
recs=[];o=16
while o+8<=len(b):
    n=struct.unpack_from('<I',b,o)[0]; recs.append((o,n,n==1 and b[o+8]==3)); o+=8+n
com=[i for i,r in enumerate(recs) if r[2]]
def group(k): return recs[(com[k-1]+1 if k else 0):com[k]+1]
if mode=='body': o,n,_=group(3)[4]; b[o+8+n//2]^=1
if mode=='len': o,n,_=group(3)[4]; b[o]^=0x10
if mode=='biglen': o,n,_=group(3)[4]; b[o+3]^=0x7f
if mode=='marker': o,n,_=group(3)[-1]; b[o+5]^=1
if mode=='two': 
    for k in (3,11): o,n,_=group(k)[4]; b[o+8+n//2]^=1
if mode=='lastmid': o,n,_=group(19)[4]; b[o+8+n//2]^=1
if mode=='lastmarker': o,n,_=group(19)[-1]; b[o+5]^=1
if mode=='cut': b=b[:group(19)[5][0]+7]
if mode=='zeros':
    o,n,_=group(19)[4]; e=group(19)[7][0]; b[o:e]=bytes(e-o)
open(p,'wb').write(b)
