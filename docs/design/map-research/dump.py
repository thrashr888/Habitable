import sys,re,glob,os,json
sub=json.load(open('sub.json'))['sub']
d=sys.argv[1]
res_re=re.compile(r'^\s*(resource|data|module)\s+"([^"]+)"(?:\s+"([^"]+)")?\s*\{',re.M)
def body(t,i):
    k=0
    for j in range(i,len(t)):
        if t[j]=='{':k+=1
        elif t[j]=='}':
            k-=1
            if k==0:return t[i:j]
items=[]
for f in sorted(glob.glob(d+'/*.tf')):
    t=open(f).read()
    for m in res_re.finditer(t):
        kind,a,b=m.groups(); bd=body(t,m.end()-1)
        key = f'{a}.{b}' if kind=='resource' else (f'data.{a}.{b}' if kind=='data' else f'module.{a}')
        items.append((key,os.path.basename(f),bd))
keys={k for k,_,_ in items}
for k,f,bd in items:
    refs=sorted({r for r in re.findall(r'\b((?:data\.)?[a-z0-9]+_[a-z0-9_]+\.[A-Za-z0-9_-]+|module\.[A-Za-z0-9_-]+)',bd) if r in keys and r!=k})
    ce='×' if re.search(r'^\s*(count|for_each)\s*=',bd,re.M) else ''
    print(f"{k}{ce} | {f} | {sub.get(k.split('.')[0],'')} | -> {', '.join(refs)}")
