import os,re,json,collections,glob,sys
R=os.path.dirname(os.path.abspath(__file__))
# subcategory lookup from provider docs
sub={}
for p,pre in [('aws','aws_'),('google','google_'),('azurerm','azurerm_')]:
    for f in glob.glob(f'{R}/{p}/website/docs/r/*'):
        b=os.path.basename(f).split('.')[0]
        m=re.search(r'^subcategory:\s*"?([^"\n]+)"?',open(f,errors='ignore').read(2000),re.M)
        if m: sub[pre+b]=m.group(1).strip()
res_re=re.compile(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{',re.M)
data_re=re.compile(r'^\s*data\s+"([^"]+)"\s+"([^"]+)"\s*\{',re.M)
mod_re=re.compile(r'^\s*module\s+"([^"]+)"\s*\{',re.M)
def body(t,i):
    d=0
    for j in range(i,len(t)):
        if t[j]=='{': d+=1
        elif t[j]=='}':
            d-=1
            if d==0: return t[i:j]
    return t[i:]
rows=[];mods=[];datas=0
for repo in sorted(os.listdir(f'{R}/corpus')):
    for f in glob.glob(f'{R}/corpus/{repo}/**/*.tf',recursive=True):
        if '/.terraform/' in f: continue
        t=open(f,errors='ignore').read()
        d=os.path.dirname(f)
        for m in res_re.finditer(t):
            rows.append(dict(repo=repo,dir=d,file=os.path.basename(f),type=m.group(1),name=m.group(2),body=body(t,m.end()-1)))
        datas+=len(data_re.findall(t))
        mods+= [(repo,d,x) for x in mod_re.findall(t)]
N=len(rows)
print('resources',N,'data sources',datas,'module calls',len(mods),'dirs',len({r["dir"] for r in rows}))
print('per repo',collections.Counter(r['repo'] for r in rows).most_common())
prov=collections.Counter(r['type'].split('_')[0] for r in rows); print('providers',prov.most_common(12))
generic={'this','main','default','example','current','primary','this_','foo','test','default_'}
g=sum(1 for r in rows if r['name'] in generic); print(f'generic names {g} ({g/N:.0%})')
print('top names',collections.Counter(r['name'] for r in rows).most_common(25))
# name tokens
tok=collections.Counter(t for r in rows for t in re.split(r'[_-]',r['name']) if t)
print('top name tokens',tok.most_common(40))
# redundancy: name tokens all appear in type
red=sum(1 for r in rows if set(x for x in re.split(r'[_-]',r['name']) if x) <= set(r['type'].split('_'))); print(f'name only repeats type words {red} ({red/N:.0%})')
# subcategory coverage
cl=[r for r in rows if r['type'].split('_')[0] in('aws','google','azurerm')]
cov=sum(1 for r in cl if r['type'] in sub); print(f'cloud resources {len(cl)}, with docs subcategory {cov} ({cov/max(1,len(cl)):.0%})')
print('top subcategories',collections.Counter(sub.get(r['type'],'?') for r in cl).most_common(30))
# file names
fn=collections.Counter(r['file'] for r in rows); print(f"in main.tf {fn['main.tf']} ({fn['main.tf']/N:.0%})"); print('top files',fn.most_common(30))
# child resources
bydir=collections.defaultdict(list)
for r in rows: bydir[r['dir']].append(r)
child=0;childtypes=collections.Counter()
for d,rs in bydir.items():
    types={r['type'] for r in rs}
    for r in rs:
        par=[t for t in types if t!=r['type'] and r['type'].startswith(t+'_')]
        if par and any(re.search(re.escape(p)+r'\.',r['body']) for p in par):
            child+=1; childtypes[r['type']]+=1
print(f'child/facet resources {child} ({child/N:.0%})',childtypes.most_common(15))
# count/for_each
ce=sum(1 for r in rows if re.search(r'^\s*(count|for_each)\s*=',r['body'],re.M)); print(f'count/for_each {ce} ({ce/N:.0%})')
# dependency depth per dir
ref=re.compile(r'\b((?:aws|google|azurerm|kubernetes|helm|random|null|tls|cloudflare|github|fastly|time)_[a-z0-9_]+)\.([A-Za-z0-9_-]+)')
depths=[];edgesN=0;iso=0
for d,rs in bydir.items():
    keys={(r['type'],r['name']) for r in rs}
    deps={(r['type'],r['name']):{k for k in ref.findall(r['body']) if k in keys and k!=(r['type'],r['name'])} for r in rs}
    edgesN+=sum(len(v) for v in deps.values())
    memo={}
    def depth(k,seen=()):
        if k in memo: return memo[k]
        if k in seen: return 0
        v=1+max([depth(x,seen+(k,)) for x in deps[k]] or [0]); memo[k]=v; return v
    for k in deps: depths.append(depth(k))
    iso+=sum(1 for k,v in deps.items() if not v and not any(k in w for w in deps.values()))
print('edges',edgesN,'isolated (no in-dir refs either way)',iso,f'({iso/N:.0%})','depth dist',sorted(collections.Counter(depths).items()))
json.dump({'sub':sub},open(f'{R}/sub.json','w'))
# name-stem clustering
exact=0;stem2=0;stem1=0
for d,rs in bydir.items():
    byname=collections.Counter(r['name'] for r in rs)
    ty=collections.defaultdict(set)
    for r in rs: ty[r['name']].add(r['type'])
    s2=collections.defaultdict(set);s1=collections.defaultdict(set)
    for r in rs:
        t=[x for x in re.split(r'[_-]',r['name']) if x]
        s2['_'.join(t[:2])].add(r['type']); s1[t[0] if t else ''].add(r['type'])
    for r in rs:
        t=[x for x in re.split(r'[_-]',r['name']) if x]
        if len(ty[r['name']])>1: exact+=1
        if len(s2['_'.join(t[:2])])>1: stem2+=1
        if t and len(s1[t[0]])>2: stem1+=1
print(f'same exact name as a different-type resource: {exact/N:.0%}; shares 2-token prefix w/ other type: {stem2/N:.0%}; shares first token with 3+ types: {stem1/N:.0%}')
# cross-workspace refs
xs=sum(1 for r in rows if re.search(r'data\.(tfe_outputs|terraform_remote_state)\.',r['body']))
print(f'resources reading another workspace (tfe_outputs/remote_state): {xs} ({xs/N:.0%})')
dirs_x=len({r['dir'] for r in rows if re.search(r'data\.(tfe_outputs|terraform_remote_state)\.',r['body'])}); print('dirs with cross-workspace refs',dirs_x,'of',len(bydir))
