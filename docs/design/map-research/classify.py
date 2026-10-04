import sys,re,glob,os,json,collections
sub=json.load(open('sub.json'))['sub']
KIND_SUB={
 'front':['Route 53','CloudFront','ELB','API Gateway','WAF','ACM','Global Accelerator','Cloud DNS','Front Door','DNS','Application Gateway','CDN'],
 'compute':['EC2 (Elastic','ECS','EKS','Lambda','App Runner','Batch','Elastic Beanstalk','Bedrock','SageMaker','Cloud Run','Cloud Functions','Kubernetes (Container)','Container','App Service','Compute','Cognito','Chatbot','Lightsail'],
 'data':['RDS','DynamoDB','S3 (','ElastiCache','OpenSearch','Redshift','Glue','Athena','EFS','BigQuery','Cloud SQL','Cloud Storage','Spanner','Firestore','Memorystore','Database','Storage','CosmosDB','Backup','QuickSight','DocumentDB','MemoryDB','Lake Formation'],
 'messaging':['SQS','SNS','EventBridge','Kinesis','SES','Pinpoint','SFN','Step Functions','Pub/Sub','Cloud Tasks','Cloud Scheduler','Messaging','MQ','End User Messaging'],
 'network':['VPC','Transit Gateway','Direct Connect','VPN','Network Firewall','Network','Cloud NAT'],
 'identity':['IAM','KMS','Secrets Manager','SSM','Secret Manager','Cloud IAM','Key Vault','Authorization','Resource Manager','Cloud Platform','Organizations','Shield'],
 'observe':['CloudWatch','X-Ray','Logging','Monitoring','Security Hub','GuardDuty','CloudTrail','Config','Inspector'],
 'delivery':['ECR','CodePipeline','CodeBuild','CodeDeploy','CodeStar','Artifact Registry','Cloud Build'],
}
TYPE_OVERRIDE=[(r'^google_compute_(network|subnetwork|firewall|router|route|global_address|address)',"network"),
 (r'^google_compute_(url_map|target_https?_proxy|global_forwarding_rule|forwarding_rule|backend_service|ssl_certificate|managed_ssl)',"front"),
 (r'^aws_(security_group|network_acl|vpc_endpoint)',"network"),(r'^aws_(lb|alb)',"front"),
 (r'^(random|null|time|tls|terraform)_',"util"),(r'^(github|tfe)_',"delivery"),(r'^(kubernetes|helm)_',"compute")]
SUPPORT_TYPES=re.compile(r'(_policy_attachment|_role_policy|_iam_|^aws_iam|_security_group_rule|^aws_security_group$|_subnet_group|_parameter_group|_log_group|_metric_alarm|_route_table_association|_secret_version|_public_access_block|_ownership_controls|_server_side_encryption|_versioning|_lifecycle_configuration|_event_target|_subscription|_permission$|_listener_rule|_target_group_attachment|^aws_route53_record|_kms_|_policy$)')
def kind(t):
    for rx,k in TYPE_OVERRIDE:
        if re.search(rx,t): return k
    s=sub.get(t,'')
    for k,lst in KIND_SUB.items():
        if any(s.startswith(x) for x in lst): return k
    return 'other'
res_re=re.compile(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{',re.M)
def body(t,i):
    k=0
    for j in range(i,len(t)):
        if t[j]=='{':k+=1
        elif t[j]=='}':
            k-=1
            if k==0:return t[i:j]
def load(d):
    R=[]
    for f in sorted(glob.glob(d+'/*.tf')):
        t=open(f).read()
        for m in res_re.finditer(t):
            bd=body(t,m.end()-1)
            R.append(dict(key=f'{m.group(1)}.{m.group(2)}',type=m.group(1),name=m.group(2),file=os.path.basename(f),body=bd,multi=bool(re.search(r'^\s*(count|for_each)\s*=',bd,re.M))))
    return R
def run(d,verbose=True):
    R=load(d); keys={r['key'] for r in R}; types={r['type'] for r in R}
    for r in R:
        r['kind']=kind(r['type'])
        r['refs']={x for x in re.findall(r'\b([a-z0-9]+_[a-z0-9_]+\.[A-Za-z0-9_-]+)',r['body']) if x in keys and x!=r['key']}
    by={r['key']:r for r in R}
    refby=collections.defaultdict(set)
    for r in R:
        for x in r['refs']: refby[x].add(r['key'])
    def is_support(r):
        if any(r['type']!=t and r['type'].startswith(t+'_') and any(x.startswith(t+'.') for x in r['refs']) for t in types): return True
        if r['kind'] in('identity','observe','util'): return True
        return bool(SUPPORT_TYPES.search(r['type']))
    anchors=[r for r in R if not is_support(r)]
    A={r['key'] for r in anchors}
    owner={}
    # attach supports to anchor: anchor references it, or it references anchor, BFS up to 3 hops
    for r in R:
        if r['key'] in A: continue
        frontier=[r['key']];seen={r['key']};found=None
        for _ in range(3):
            nxt=[]
            for k in frontier:
                for x in list(refby[k])+list(by[k]['refs']):
                    if x in seen: continue
                    if x in A: found=found or x
                    seen.add(x);nxt.append(x)
            if found:break
            frontier=nxt
        owner[r['key']]=found
    # name-stem merge of anchors
    def stem(n):
        t=[x for x in re.split(r'[_-]',n) if x and x not in('dublin','london','east','west','a','b','c','1','2','3','primary','secondary','us','eu','ca','central')]
        return '_'.join(t[:2])
    parent={r['key']:r['key'] for r in anchors}
    def find(x):
        while parent[x]!=x: parent[x]=parent[parent[x]]; x=parent[x]
        return x
    def union(a,b): parent[find(a)]=find(b)
    for r in anchors:
        for x in r['refs']:
            if x in A and sub.get(by[x]['type'])==sub.get(r['type']) and sub.get(r['type']): union(r['key'],x)
    st=collections.defaultdict(list)
    for r in anchors: st[stem(r['name'])].append(r['key'])
    for k,v in st.items():
        for x in v[1:]: union(x,v[0])
    comp=collections.defaultdict(list)
    for r in anchors: comp[find(r['key'])].append(r)
    unowned=[k for k,v in owner.items() if v is None]
    if verbose:
        print(f"{d.split('/')[-1]}: {len(R)} resources -> {len(anchors)} anchors -> {len(comp)} components; {len(R)-len(anchors)-len(unowned)} folded into anchors; {len(unowned)} on supporting shelf")
        print(' kinds of anchors',collections.Counter(r['kind'] for r in anchors).most_common())
        for s,rs in sorted(comp.items(),key=lambda x:-len(x[1])):
            s=stem(by[s]['name'])
            fold=sum(1 for k,v in owner.items() if v in {r['key'] for r in rs})
            print(f"  [{s}] {', '.join(r['key']+('×' if r['multi'] else '') for r in rs)}  (+{fold} folded) kind={collections.Counter(r['kind'] for r in rs).most_common(1)[0][0]}")
        print('  shelf:',collections.Counter(by[k]['kind'] for k in unowned))
    return len(R),len(anchors),len(comp),len(unowned)
if __name__=='__main__':
    for d in sys.argv[1:]: run(d)
