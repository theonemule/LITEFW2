# Parse native nftables user rules into the LiteFW JSON contract.
# Unknown expressions are retained verbatim, but marked read-only.
function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
function tokenize(line,    i,c,cur,inq,have,L) {
  NT=0;cur="";inq=0;have=0;L=length(line)
  delete T
  for(i=1;i<=L;i++) {
    c=substr(line,i,1)
    if(inq){
      if(c=="\\" && i<L){i++;cur=cur substr(line,i,1);continue}
      if(c=="\""){inq=0;continue}
      cur=cur c;continue
    }
    if(c=="\""){inq=1;have=1;continue}
    if(c==" " || c=="\t"){
      if(have){T[++NT]=cur;cur="";have=0}
      continue
    }
    cur=cur c;have=1
  }
  if(have)T[++NT]=cur
}
function readset(start,    x,out) {
  if(T[start]!="{") return T[start]
  out=""
  for(x=start+1;x<=NT && T[x]!="}";x++)out=out T[x]
  LAST=x
  return out
}
NF {
  tokenize($0)
  iif="";oif="";src="";dst="";srcports="";ports="";proto=""
  comment="";target="";todst="";odd=0
  for(i=1;i<=NT;i++){
    t=T[i]
    if(t=="iifname")iif=T[++i]
    else if(t=="oifname")oif=T[++i]
    else if(t=="ip" && (T[i+1]=="saddr"||T[i+1]=="daddr")){
      field=T[++i];val=T[++i]
      if(val=="!="){odd=1;val=T[++i]}
      if(val=="{"){val=readset(i);i=LAST}
      if(field=="saddr")src=val;else dst=val
    }
    else if(t=="meta" && T[i+1]=="l4proto"){i++;proto=T[++i]}
    else if(t=="tcp" || t=="udp"){
      proto=t
      if(T[i+1]=="sport" || T[i+1]=="dport"){
        field=T[++i];val=T[++i]
        if(val=="{"){val=readset(i);i=LAST}
        if(field=="sport")srcports=val;else ports=val
      }
    }
    else if(t=="dnat"){
      target="DNAT"
      if(T[i+1]=="ip" && T[i+2]=="to"){i+=2;todst=T[++i]}
      else odd=1
    }
    else if(t=="masquerade")target="MASQUERADE"
    else if(t=="accept")target="ACCEPT"
    else if(t=="drop")target="DROP"
    else if(t=="reject")target="REJECT"
    else if(t=="with" && T[i+1]=="icmp" && T[i+2]=="port-unreachable")i+=2
    else if(t=="with" && T[i+1]=="icmpx" && T[i+2]=="type" && T[i+3]=="port-unreachable")i+=3
    else if(t=="comment")comment=T[++i]
    else odd=1
  }
  id="";desc=""
  if(comment ~ /^lfw:/){
    c=substr(comment,5);sp=index(c," ")
    if(sp){id=substr(c,1,sp-1);desc=substr(c,sp+1)}else id=c
  }
  if(length(id)!=8 || id !~ /^[0123456789abcdef]+$/)odd=1
  sub(/\/32$/,"",src);sub(/\/32$/,"",dst)
  managed=(id!="" && !odd)?"true":"false"
  printf "{\"id\":\"%s\",\"description\":\"%s\",\"in\":\"%s\",\"out\":\"%s\",\"src\":\"%s\",\"dst\":\"%s\",\"srcPorts\":\"%s\",\"proto\":\"%s\",\"ports\":\"%s\",\"target\":\"%s\",\"toDestination\":\"%s\",\"managed\":%s,\"raw\":\"%s\"}\n",\
    jesc(id),jesc(desc),jesc(iif),jesc(oif),jesc(src),jesc(dst),jesc(srcports),jesc(proto),jesc(ports),jesc(target),jesc(todst),managed,jesc($0)
}