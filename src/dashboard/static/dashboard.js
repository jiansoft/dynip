let latestProviders = [];
let refreshInterval = null;
let isRefreshing = true;
async function refresh(){
 try {
   const r=await fetch('/api/status.json',{cache:'no-store'}); if(!r.ok)return;
   const data=await r.json(); latestProviders=data.providers||[];
   document.getElementById('desired-ip').textContent=data.desired_ip||data.public_ip||'-';
   document.getElementById('public-ip-source').textContent=data.public_ip_source||'-';
   document.getElementById('public-ip-stun-status').textContent=data.public_ip_stun_status||'-';
   document.getElementById('public-ip-stun-error').textContent=data.public_ip_stun_error?' ('+data.public_ip_stun_error+')':'';
   document.getElementById('last-updated').textContent='Last Updated: '+formatRfc3339(new Date());
   renderProviders();
 } catch(e) { console.error(e); }
}
// API 回傳是扁平陣列；每兩筆依固定契約組成一張 provider 卡。
function renderProviders(){
 const cards=[];
 for(let i=0;i<latestProviders.length;i+=2){
  cards.push(providerCard(latestProviders[i],latestProviders[i+1]));
 }
 document.getElementById('providers').innerHTML=cards.join('');
}
// 只負責一個 IP family 的狀態；避免 A 與 AAAA 共用 retry/error 顯示。
function familyStatus(p){
 const isFailed=p.display_status==='failed'||p.display_status==='retry_deferred';
 const timeLabel=isFailed?'Next':'Updated';
 const timeValue=isFailed?formatTime(p.next_retry_at):formatTime(p.updated_at);
 const labelText=p.family==='ipv4'?'A / IPv4':'AAAA / IPv6';
 return `<section class="family ${p.display_status}"><header><span>${labelText}</span><strong>${label(p.display_status)}</strong></header><dl><div><dt>Current IP</dt><dd>${escapeHtml(p.current_ip)||'-'}</dd></div><div><dt>Retry</dt><dd>${p.retry_count}</dd></div><div><dt>${timeLabel}</dt><dd>${timeValue}</dd></div><div><dt>Last error</dt><dd>${escapeHtml(p.last_error)||'-'}</dd></div></dl><button type="button" onclick="showDetail('${escapeAttr(p.name)}','${escapeAttr(p.family)}')">View Details</button></section>`;
}
// 外層卡片只顯示 provider 名稱；內部固定並排 IPv4 與 IPv6 子卡。
function providerCard(ipv4,ipv6){
 const name=(ipv4||ipv6||{}).name||'provider';
 return `<article class="provider"><header><span>${escapeHtml(name)}</span></header><div class="family-grid">${familyStatus(ipv4)}${familyStatus(ipv6)}</div></article>`;
}
function showDetail(name,family){
 const p=latestProviders.find(x=>x.name===name&&x.family===family); if(!p)return;
 document.getElementById('detail-title').textContent=p.name+' '+(p.family==='ipv4'?'A / IPv4':'AAAA / IPv6')+' - detail';
 document.getElementById('detail-body').innerHTML=[
 ['current_ip',p.current_ip||'-'],['desired_ip',p.desired_ip||'-'],['status',p.status||p.display_status],['display_status',label(p.display_status)],['retry_count',p.retry_count],['next_retry_at',formatTime(p.next_retry_at)],['last_error',p.last_error||'-'],['updated_at',formatTime(p.updated_at)]
 ].map(([k,v])=>`<div><dt>${k}</dt><dd>${escapeHtml(v)}</dd></div>`).join('');
 document.getElementById('detail-panel').hidden=false;
}
function hideDetail(){document.getElementById('detail-panel').hidden=true;}
function label(v){return String(v||'').replace('_',' ');}
function formatTime(v){return v?formatRfc3339(new Date(v*1000)):'-';}
function formatRfc3339(d){
 const pad=n=>String(Math.trunc(Math.abs(n))).padStart(2,'0');
 const offsetMinutes=-d.getTimezoneOffset();
 const sign=offsetMinutes>=0?'+':'-';
 const offsetHours=pad(offsetMinutes/60);
 const offsetMins=pad(offsetMinutes%60);
 return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${sign}${offsetHours}:${offsetMins}`;
}
function escapeAttr(v){return String(v||'').replace(/['\\]/g,'');}
function escapeHtml(v){return String(v||'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));}
function startRefresh(){
  if (refreshInterval) clearInterval(refreshInterval);
  refreshInterval = setInterval(refresh, 30000);
}
function toggleRefresh(){
  isRefreshing = !isRefreshing;
  const btn = document.getElementById('refresh-toggle');
  if (isRefreshing) {
    btn.textContent = '⟳ Auto-refresh: ON';
    btn.classList.remove('off');
    refresh();
    startRefresh();
  } else {
    btn.textContent = '⟳ Auto-refresh: OFF';
    btn.classList.add('off');
    if (refreshInterval) {
      clearInterval(refreshInterval);
      refreshInterval = null;
    }
  }
}
