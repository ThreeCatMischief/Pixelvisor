#pragma once

// Web pages served at GET /. kPage is the full control and settings UI, for any browser
// (Windows, Linux, phones). kSetupPage is served instead while the setup portal is open.
// Both use only the public API.

#define LB_PAGE_STYLE R"css(
:root{--bg:#f4f4f5;--card:#fff;--fg:#18181b;--muted:#71717a;--line:#e4e4e7;--acc:#2563eb;--ok:#16a34a;--err:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#09090b;--card:#18181b;--fg:#f4f4f5;--muted:#a1a1aa;--line:#27272a;--acc:#3b82f6}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,-apple-system,sans-serif;display:flex;justify-content:center;padding:24px 16px}
main{width:100%;max-width:440px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px}
header,.line{display:flex;align-items:center;justify-content:space-between;gap:12px}
h1{font-size:18px;margin:0;flex:1}
#status{font-size:13px;color:var(--muted)}
#status::before{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--muted);margin-right:6px}
#status.ok::before{background:var(--ok)}#status.err::before{background:var(--err)}
.row{display:grid;grid-template-columns:96px 1fr 44px;gap:10px;align-items:center;margin:12px 0}
label,.val,.note{font-size:13px;color:var(--muted)}.val{text-align:right}
input[type=range],select,input[type=text],input[type=number],input[type=password]{width:100%}
input[type=text],input[type=number],input[type=password],select{font:inherit;font-size:14px;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:transparent;color:inherit}
input[type=color]{width:48px;height:32px;border:1px solid var(--line);border-radius:6px;background:none;padding:0}
button{font:inherit;font-size:14px;padding:6px 12px;border:1px solid var(--line);border-radius:6px;background:transparent;color:inherit;cursor:pointer}
.seg{display:flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;margin-top:4px}
.seg button{flex:1;border:0;border-radius:0}
.on,button.primary{background:var(--acc)!important;color:#fff;border-color:var(--acc)}
hr{border:0;border-top:1px solid var(--line);margin:16px 0}
.hide{display:none}
details{margin-top:12px}summary{cursor:pointer;font-weight:600;margin-bottom:8px}
.wb{display:flex;gap:6px}
.list button{display:flex;justify-content:space-between;width:100%;margin:4px 0;text-align:left}
.err{color:var(--err)}
)css"

static const char kPage[] = R"html(<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pixelvisor</title>
<style>)html" LB_PAGE_STYLE R"html(</style>
</head>
<body>
<main>
<header><h1 id="name">Pixelvisor</h1><span id="status">connecting</span><button id="power">Off</button></header>
<div class="row"><label for="bri">Brightness</label><input type="range" id="bri" min="0" max="255"><span class="val" id="briv"></span></div>
<hr>
<div class="seg" id="mode"><button data-m="solid">Color</button><button data-m="effect">Effect</button></div>
<div class="row" id="effrow"><label for="eff">Effect</label><select id="eff"></select><span></span></div>
<div class="row" id="c1row"><label for="c1">Color</label><input type="color" id="c1"><span></span></div>
<div class="row" id="c2row"><label for="c2">Color 2</label><input type="color" id="c2"><span></span></div>
<div class="row" id="sprow"><label for="sp">Speed</label><input type="range" id="sp" min="0" max="255"><span class="val" id="spv"></span></div>
<p id="rt" class="note hide"></p>

<details id="settings"><summary>Settings</summary>
<div class="row"><label for="cname">Name</label><input type="text" id="cname" maxlength="32"><span></span></div>
<div class="row"><label for="chost">Hostname</label><input type="text" id="chost" maxlength="24"><span class="val">.local</span></div>
<div class="row"><label for="ccount">LED count</label><input type="number" id="ccount" min="1" max="480"><span></span></div>
<div class="row"><label for="cpin">Data pin</label><input type="number" id="cpin" min="0" max="48"><span class="val">GPIO</span></div>
<div class="row"><label for="corder">Color order</label><select id="corder"><option>RGB</option><option>RBG</option><option>GRB</option><option>GBR</option><option>BRG</option><option>BGR</option></select><span></span></div>
<div class="row"><label for="crev">Reverse</label><input type="checkbox" id="crev"><span></span></div>
<div class="row"><label for="cmax">Current limit</label><input type="number" id="cmax" min="0" max="20000"><span class="val">mA</span></div>
<div class="row"><label>White balance</label><div class="wb"><input type="number" id="wbr" min="0" max="255"><input type="number" id="wbg" min="0" max="255"><input type="number" id="wbb" min="0" max="255"></div><span></span></div>
<div class="row"><label for="cgamma">Gamma</label><input type="number" id="cgamma" min="1" max="3" step="0.1"><span></span></div>
<div class="row"><label for="cdither">Dither</label><input type="checkbox" id="cdither"><span></span></div>
<div class="row"><label for="cpower">After power loss</label><select id="cpower"><option value="restore">Restore</option><option value="on">On</option><option value="off">Off</option></select><span></span></div>
<div class="line"><span id="cmsg" class="note"></span><button id="csave" class="primary">Save</button></div>
<p class="note">Reverse: the first LED is at the right end. Current limit: your supply's rating minus 300 mA; 0 turns limiting off.</p>
</details>

<details><summary>Device</summary>
<p id="info" class="note"></p>
<div class="line"><button id="identify">Identify</button><button id="reboot">Reboot</button><button id="forget">Forget WiFi</button></div>
<p class="note">Firmware update: choose firmware.bin from a release.</p>
<div class="line"><input type="file" id="fw" accept=".bin"><button id="upload">Update</button></div>
<p id="fwmsg" class="note"></p>
</details>
</main>
<script>
const $=id=>document.getElementById(id);
let st=null,fx=[],cfg=null,pending={},busy=false;
const hex=c=>'#'+c.map(v=>v.toString(16).padStart(2,'0')).join('');
const rgb=h=>[1,3,5].map(p=>parseInt(h.substr(p,2),16));
const show=(id,v)=>$(id).classList.toggle('hide',!v);
function status(ok,msg){const s=$('status');s.className=ok?'ok':'err';s.textContent=msg}
async function call(method,path,body){
  const r=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:body&&JSON.stringify(body)});
  const j=await r.json();
  if(!r.ok)throw new Error(j.error||r.status);
  return j;
}
function render(){
  if(!st)return;
  $('power').textContent=st.on?'On':'Off';$('power').classList.toggle('on',st.on);
  $('bri').value=st.brightness;$('briv').textContent=Math.round(st.brightness/2.55)+'%';
  document.querySelectorAll('#mode button').forEach(b=>b.classList.toggle('on',b.dataset.m==st.mode));
  const eff=st.mode=='effect',uses=(fx.find(f=>f.id==st.effect.id)||{uses:[]}).uses;
  $('eff').value=st.effect.id;
  show('effrow',eff);show('c1row',!eff||uses.includes('color'));
  show('c2row',eff&&uses.includes('color2'));show('sprow',eff&&uses.includes('speed'));
  $('c1').value=hex(st.color);$('c2').value=hex(st.effect.color2);
  $('sp').value=st.effect.speed;$('spv').textContent=st.effect.speed;
  show('rt',st.realtime.active);$('rt').textContent='Realtime stream from '+st.realtime.source;
}
function patch(p){
  for(const k in p)pending[k]=k=='effect'?{...pending.effect,...p.effect}:p[k];
  if(p.effect)st.effect={...st.effect,...p.effect};
  for(const k of ['on','brightness','mode','color'])if(k in p)st[k]=p[k];
  render();
  if(!busy)flush();
}
async function flush(){
  busy=true;
  while(Object.keys(pending).length){
    const p=pending;pending={};
    try{const r=await call('PATCH','/api/state',p);if(!Object.keys(pending).length)st=r;status(true,'connected')}
    catch(e){status(false,e.message)}
  }
  busy=false;render();
}
async function load(){
  try{
    if(!fx.length){fx=await call('GET','/api/effects');$('eff').innerHTML=fx.map(f=>`<option value="${f.id}">${f.name}</option>`).join('')}
    const s=await call('GET','/api/state');if(!busy){st=s;render()}
    status(true,'connected');
  }catch(e){status(false,e.message)}
}
async function loadInfo(){
  const i=await call('GET','/api/info');
  $('name').textContent=document.title=i.name;
  $('info').textContent=`Firmware ${i.fw} · ${i.board} · ${i.led_count} LEDs · ${i.ip} · ${i.rssi} dBm · up ${Math.round(i.uptime_s/60)} min`;
}
function fillConfig(c){
  cfg=c;
  $('cname').value=c.name;$('chost').value=c.hostname;$('ccount').value=c.led_count;$('cpin').value=c.data_pin;
  $('corder').value=c.color_order;$('crev').checked=c.reverse;$('cmax').value=c.max_current_ma;
  [$('wbr').value,$('wbg').value,$('wbb').value]=c.white_balance;$('cgamma').value=c.gamma;
  $('cdither').checked=c.dither;$('cpower').value=c.power_on;
  $('cmsg').textContent=c.reboot_required?'Saved. Reboot to apply LED count, pin or hostname.':'';
}
$('settings').ontoggle=()=>{if($('settings').open)call('GET','/api/config').then(fillConfig).catch(e=>$('cmsg').textContent=e.message)};
$('csave').onclick=async()=>{
  const n=id=>+$(id).value;
  const next={name:$('cname').value,hostname:$('chost').value,led_count:n('ccount'),data_pin:n('cpin'),color_order:$('corder').value,
    reverse:$('crev').checked,max_current_ma:n('cmax'),white_balance:[n('wbr'),n('wbg'),n('wbb')],gamma:n('cgamma'),
    dither:$('cdither').checked,power_on:$('cpower').value};
  const diff={};for(const k in next)if(JSON.stringify(next[k])!=JSON.stringify(cfg[k]))diff[k]=next[k];
  if(!Object.keys(diff).length)return;
  try{fillConfig(await call('PATCH','/api/config',diff));if(!$('cmsg').textContent)$('cmsg').textContent='Saved.';loadInfo()}
  catch(e){$('cmsg').textContent=e.message}
};
function restarted(msg){$('fwmsg').textContent=msg;setTimeout(()=>location.reload(),8000)}
$('reboot').onclick=()=>call('POST','/api/reboot').then(()=>restarted('Restarting…'));
$('forget').onclick=()=>{
  if(confirm('Forget the WiFi network? Pixelvisor restarts and opens its setup network.'))
    call('DELETE','/api/wifi').then(()=>$('fwmsg').textContent='Restarting into setup. Join the "Pixelvisor-…" network to set it up again.');
};
$('upload').onclick=()=>{
  const f=$('fw').files[0];if(!f)return;
  const x=new XMLHttpRequest();
  x.open('POST','/api/ota');x.setRequestHeader('Content-Type','application/octet-stream');
  x.upload.onprogress=e=>$('fwmsg').textContent=`Uploading ${Math.round(e.loaded/e.total*100)} %`;
  x.onload=()=>x.status==200?restarted('Updated. Restarting…'):($('fwmsg').textContent='Update failed: '+(JSON.parse(x.responseText).error||x.status));
  x.onerror=()=>$('fwmsg').textContent='Update failed: connection lost';
  x.send(f);
};
$('power').onclick=()=>st&&patch({on:!st.on});
$('bri').oninput=e=>patch({brightness:+e.target.value,transition_ms:150});
document.querySelectorAll('#mode button').forEach(b=>b.onclick=()=>patch({mode:b.dataset.m}));
$('eff').onchange=e=>patch({mode:'effect',effect:{id:e.target.value}});
$('c1').oninput=e=>patch({color:rgb(e.target.value),transition_ms:150});
$('c2').oninput=e=>patch({effect:{color2:rgb(e.target.value)},transition_ms:150});
$('sp').oninput=e=>patch({effect:{speed:+e.target.value}});
$('identify').onclick=()=>call('POST','/api/identify').catch(e=>status(false,e.message));
loadInfo().catch(()=>{});
load();setInterval(load,3000);
</script>
</body>
</html>
)html";

static const char kSetupPage[] = R"html(<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pixelvisor setup</title>
<style>)html" LB_PAGE_STYLE R"html(</style>
</head>
<body>
<main>
<header><h1>Pixelvisor setup</h1></header>
<p class="note">Choose the WiFi network Pixelvisor should join.</p>
<div class="list" id="nets"><p class="note">Scanning…</p></div>
<div class="line"><span></span><button id="rescan">Scan again</button></div>
<hr>
<div class="row"><label for="ssid">Network</label><input type="text" id="ssid" maxlength="32" autocapitalize="none"><span></span></div>
<div class="row"><label for="pass">Password</label><input type="password" id="pass" maxlength="63"><span></span></div>
<div class="line"><span id="msg" class="note"></span><button id="save" class="primary">Connect</button></div>
</main>
<script>
const $=id=>document.getElementById(id);
const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function scan(){
  $('nets').innerHTML='<p class="note">Scanning…</p>';
  try{
    const list=await (await fetch('/api/wifi/scan')).json();
    $('nets').innerHTML=list.length?list.map((n,i)=>`<button data-i="${i}"><span>${esc(n.ssid)}</span><span class="note">${n.secure?'🔒 ':''}${n.rssi} dBm</span></button>`).join(''):'<p class="note">No networks found.</p>';
    $('nets').querySelectorAll('button').forEach(b=>b.onclick=()=>{$('ssid').value=list[b.dataset.i].ssid;$('pass').focus()});
  }catch(e){$('nets').innerHTML='<p class="note err">Scan failed.</p>'}
}
$('rescan').onclick=scan;
$('save').onclick=async()=>{
  const r=await fetch('/api/wifi',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:$('ssid').value,password:$('pass').value})});
  const j=await r.json();
  if(!r.ok){$('msg').className='note err';$('msg').textContent=j.error;return}
  $('msg').className='note';
  $('msg').textContent='Saved. Pixelvisor restarts and joins "'+$('ssid').value+'". Switch back to that network and open http://pixelvisor.local';
};
scan();
</script>
</body>
</html>
)html";
