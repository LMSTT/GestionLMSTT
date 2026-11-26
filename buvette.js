/* ================= Buvette LMSTT ================= */
(()=>{
const {rpc,toast,logout}=window.LM,PINf=()=>LM.PIN;
const E=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const eur=n=>(Math.round((+n||0)*100)/100).toLocaleString('fr-FR',{minimumFractionDigits:2,maximumFractionDigits:2})+' €';
const g=id=>document.getElementById(id);
const LS={get:(k,d)=>{try{const v=localStorage.getItem(k);return v?JSON.parse(v):d}catch(e){return d}},set:(k,v)=>{try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}}};
const uid=()=>crypto.randomUUID?crypto.randomUUID():'10000000-1000-4000-8000-100000000000'.replace(/[018]/g,c=>(c^crypto.getRandomValues(new Uint8Array(1))[0]&15>>c/4).toString(16));
let D=LS.get('bv_cache',null),cart=[],cat=null,vendeur=LS.get('bv_vendeur',''),pay=null,syncing=false;
const Q=()=>LS.get('bv_q',[]);
const T=m=>toast(m);

async function call(fn,args){const j=await rpc(fn,{p_pin:PINf(),...args});if(j&&j.code==='session'){logout(j.erreur);return null}return j}
async function charger(){const j=await call('api_bv_donnees',{});if(j&&j.ok){D=j;LS.set('bv_cache',j);return true}
 if(j&&j.erreur&&!/Connexion impossible|met du temps/.test(j.erreur))T(j.erreur);return false}

/* ---------- file d'attente hors-ligne ---------- */
function badge(){const n=Q().length,b=g('bvSync');if(!b)return;b.hidden=!n;b.textContent=n?`⏳ ${n} vente${n>1?'s':''} à envoyer`:''}
async function sync(){if(syncing||!PINf())return;const q=Q();if(!q.length){badge();return}syncing=true;
 try{const j=await call('api_bv_ventes',{p_ventes:q});if(j&&j.ok){const done=new Set([...j.acceptees,...j.refusees.map(r=>r.id)]);
   if(j.refusees.length){const err=LS.get('bv_refus',[]);LS.set('bv_refus',err.concat(j.refusees.map(r=>({...r,vente:q.find(v=>v.id===r.id)}))));T('Vente refusée : '+j.refusees[0].erreur)}
   LS.set('bv_q',Q().filter(v=>!done.has(v.id)))}}
 finally{syncing=false;badge()}}
setInterval(sync,15000);addEventListener('online',sync);

/* ---------- vues ---------- */
window.bvRender=async function(v){const box=g(v==='buvette'?'bvBox':'bvgBox');if(!D)box.innerHTML='<p class="muted">Chargement…</p>';
 await charger();await sync();if(!D){box.innerHTML='<div class="card"><p>Pas de connexion et aucune donnée en mémoire sur cet appareil.</p></div>';return}
 v==='buvette'?caisse():gestion()};

function vendeurs(){return (D.vendeurs||[]).filter(x=>x.actif!==false).map(x=>x.prenom)}
let ecran='home';
/* ---------- écran allumé : pas de veille avant 5 min sans toucher l'écran ---------- */
let wl=null,wlT=null;const onBv=()=>location.hash==='#buvette'&&!document.hidden;
async function eveil(){clearTimeout(wlT);if(!onBv()){if(wl){wl.release().catch(()=>{});wl=null}return}
 try{if(!wl&&navigator.wakeLock){wl=await navigator.wakeLock.request('screen');wl.addEventListener('release',()=>{wl=null})}}catch(e){}
 wlT=setTimeout(()=>{if(wl){wl.release().catch(()=>{});wl=null}},5*60*1000)}
addEventListener('pointerdown',eveil,{passive:true});document.addEventListener('visibilitychange',eveil);addEventListener('hashchange',eveil);
function champNom(id){return `<div class="bvnom"><label for="${id}">Ton prénom</label><input id="${id}" list="bvVendL" autocomplete="off" placeholder="Écris ton prénom" value="${E(vendeur)}"><datalist id="bvVendL">${vendeurs().map(p=>`<option value="${E(p)}">`).join('')}</datalist></div>`}
function lireNom(id){const i=g(id);if(i){vendeur=i.value.trim();LS.set('bv_vendeur',vendeur)}return vendeur}
function lierNom(id){const i=g(id);if(i)i.oninput=()=>{vendeur=i.value.trim();LS.set('bv_vendeur',vendeur);i.classList.remove('manque')}}

function caisse(){badge();eveil();const s=D.session;
 if(ecran==='home'){const ev=s&&s.evenement||{};
  g('bvBox').innerHTML=`<div class="bvhome"><span id="bvSync" class="tag t-a" hidden></span>${s?`<p class="muted">Caisse ouverte · ${E(ev.type)}${ev.adversaire?' – '+E(ev.adversaire):ev.libelle?' – '+E(ev.libelle):''}</p>`:''}
  <button type="button" class="bvbig" id="bvGo">🥤 Faire une vente</button>${s?'<button type="button" class="alt" id="bvClot">Clôturer la caisse</button>':''}</div>`;badge();
  g('bvBox').onclick=e=>{const b=e.target.closest('button');if(!b)return;if(b.id==='bvGo'){ecran='vente';cart=[];pay=null;return caisse()}if(b.id==='bvClot')return cloture()};return}
 if(!s)return ouverture();
 const cats=(D.categories||[]).filter(c=>c.actif!==false),prods=(D.produits||[]).filter(p=>p.actif!==false);
 if(cat!==null&&!cats.some(c=>c.id===cat))cat=null;
 const vis=prods.filter(p=>cat===null||p.categorie_id===cat),tot=cart.reduce((a,l)=>a+l.q*l.p,0),nb=id=>(cart.find(l=>l.id===id)||{}).q||0;
 g('bvBox').innerHTML=`<div class="bvbar"><button type="button" class="alt" id="bvHome">← Retour</button><span id="bvSync" class="tag t-a" hidden></span></div>
 ${champNom('bvNom')}
 ${cats.length?`<div class="bvcats"><button type="button" data-c="" class="${cat===null?'on':''}">Tout</button>${cats.map(c=>`<button type="button" data-c="${c.id}" class="${cat===c.id?'on':''}">${E(c.nom)}</button>`).join('')}</div>`:''}
 <div class="bvlay"><div class="bvtiles">${vis.map(p=>{const n=nb(p.id);return `<button type="button" class="bvtile${n?' sel':''}${p.stock<=p.seuil&&p.seuil>0?' bas':''}" data-p="${p.id}">${p.photo?`<img src="${E(p.photo)}" alt="">`:''}${n?`<span class="bvmoins" data-m="${p.id}" role="button" aria-label="Retirer un">−</span><span class="bvn">${n}</span>`:''}<span class="bvlab"><b>${E(p.nom)}</b><span>${eur(p.prix_vente)}</span></span></button>`}).join('')||'<p class="muted">Aucun produit. Un administrateur doit en créer dans Buvette › Gestion.</p>'}</div>
 <div class="card bvcart"><h3>Panier</h3>${cart.length?`<ul class="bvl">${cart.map(l=>`<li><span>${l.q}× ${E(l.n)}</span><span></span><span>${eur(l.q*l.p)}</span></li>`).join('')}</ul>`:'<p class="muted">Touche un produit : 1 touche = 1 article.</p>'}
 <div class="bvtot">${eur(tot)}</div>
 <div class="bvpay"><button type="button" data-pay="cb" ${cart.length?'':'disabled'}>💳 CB</button><button type="button" data-pay="especes" ${cart.length?'':'disabled'}>💶 Espèces</button><button type="button" class="alt" data-pay="offert" ${cart.length?'':'disabled'}>🎁 Offert</button></div>
 ${cart.length?'<button type="button" class="alt bvvide" id="bvVide">Vider le panier</button>':''}
 <div id="bvPay"></div></div></div>`;
 badge();lierNom('bvNom');if(pay)panneau();
 g('bvBox').onclick=e=>{const m=e.target.closest('[data-m]');if(m){const i=cart.findIndex(l=>l.id===+m.dataset.m);if(i>=0&&--cart[i].q<=0)cart.splice(i,1);pay=null;return caisse()}
  const b=e.target.closest('button');if(!b)return;const d=b.dataset;
  if(b.id==='bvHome'){ecran='home';cart=[];pay=null;return caisse()}
  if(b.id==='bvVide'){cart=[];pay=null;return caisse()}
  if(d.c!==undefined){cat=d.c?+d.c:null;return caisse()}
  if(d.p){const p=prods.find(x=>x.id===+d.p),l=cart.find(x=>x.id===p.id);l?l.q++:cart.push({id:p.id,n:p.nom,p:+p.prix_vente,q:1});pay=null;return caisse()}
  if(d.pay){if(!lireNom('bvNom')){g('bvNom').classList.add('manque');g('bvNom').focus();return T('Écris ton prénom avant d\'encaisser')}pay={mode:d.pay};return caisse()}
  if(d.ok!==undefined)return valider(d.ok)}}

function panneau(){const tot=cart.reduce((a,l)=>a+l.q*l.p,0),P=g('bvPay');
 if(pay.mode==='cb')P.innerHTML=`<p><b>Encaisse ${eur(tot)} sur le TPE.</b></p><button type="button" class="bvgo" data-ok="">✔ Paiement accepté</button>`;
 else if(pay.mode==='especes'){const b=[...new Set([tot,...[5,10,20,50].filter(x=>x>tot)])];
  P.innerHTML=`<p><b>Somme reçue ?</b></p><div class="bvgrid">${b.map(x=>`<button type="button" class="bvgo" data-ok="${x}">${x===tot?'Compte juste':eur(x)}</button>`).join('')}</div>
  <div class="row"><input id="bvRecu" type="number" inputmode="decimal" step="0.01" placeholder="Autre montant"><button type="button" data-ok="autre">OK</button></div>`}
 else P.innerHTML=`<p><b>Offert à :</b></p><input id="bvBen" placeholder="Nom (facultatif)" autocomplete="off"><div class="bvgrid" style="margin-top:8px"><button type="button" class="bvgo" data-ok="Staff">Staff</button><button type="button" class="bvgo" data-ok="Joueur">Joueur</button></div>`}

function valider(x){const tot=cart.reduce((a,l)=>a+l.q*l.p,0),v={id:uid(),session_id:D.session.id,vendeur,vendue_le:new Date().toISOString(),mode:pay.mode,lignes:cart.map(l=>({produit_id:l.id,qte:l.q,prix:l.p}))};let msg='Vente enregistrée ✔';
 if(pay.mode==='especes'){const r=x==='autre'?+String(g('bvRecu').value).replace(',','.'):+x;if(!(r>=tot-0.001))return T('Montant reçu insuffisant');v.recu=r;const rendu=r-tot;msg=rendu>0.001?`Rends ${eur(rendu)}`:'Compte juste ✔'}
 if(pay.mode==='offert'){v.beneficiaire_type=x;v.beneficiaire_nom=(g('bvBen').value||'').trim();msg='Offert enregistré ✔'}
 LS.set('bv_q',Q().concat([v]));
 for(const l of cart){const p=D.produits.find(p=>p.id===l.id);if(p)p.stock-=l.q}LS.set('bv_cache',D);
 cart=[];pay=null;caisse();grand(msg);sync()}
function grand(m){let o=g('bvFlash');if(!o){o=document.createElement('div');o.id='bvFlash';document.body.appendChild(o)}o.textContent=m;o.className='on';clearTimeout(o._t);o._t=setTimeout(()=>o.className='',m.startsWith('Rends')?4000:1500);o.onclick=()=>o.className=''}

function ouverture(){g('bvBox').innerHTML=`<div class="card bvcard"><h2>Ouvrir la caisse</h2>${champNom('bvNomO')}
 <label>Événement</label><div class="bvgrid" id="bvType">${['Pro A','Tournoi','Compétition','Stage','Autre'].map((t,i)=>`<button type="button" class="${i?'alt':''}" data-t="${t}">${t}</button>`).join('')}</div>
 <label for="bvAdv" id="bvAdvL">Adversaire</label><input id="bvAdv" autocomplete="off">
 <label for="bvFond">Fond de caisse (€)</label><input id="bvFond" type="number" inputmode="decimal" step="0.01" value="${E(LS.get('bv_fond',''))}">
 <button type="button" class="bvgo" id="bvOpen" style="margin-top:14px">Ouvrir la caisse</button></div>`;
 let type='Pro A';
 g('bvType').onclick=e=>{const b=e.target.closest('[data-t]');if(!b)return;type=b.dataset.t;for(const x of g('bvType').children)x.className=x===b?'':'alt';g('bvAdvL').textContent=type==='Pro A'?'Adversaire':'Libellé (facultatif)'};
 lierNom('bvNomO');
 g('bvOpen').onclick=async()=>{if(!lireNom('bvNomO'))return T('Écris ton prénom');const f=String(g('bvFond').value).replace(',','.');if(f===''||+f<0)return T('Indique le fond de caisse');const a=g('bvAdv').value.trim();
  const j=await call('api_bv_ouvrir',{p:{type,fond:+f,vendeur,adversaire:type==='Pro A'?a:'',libelle:type==='Pro A'?'':a}});if(!j)return;if(!j.ok)return T(j.erreur);LS.set('bv_fond',f);await charger();T('Caisse ouverte');ecran='vente';caisse()}}

function cloture(){const s=D.session,t=s.totaux||{},att=+s.fond+ +t.especes;
 g('bvBox').innerHTML=`<div class="card bvcard"><h2>Clôturer la caisse</h2>
 ${Q().length?`<p class="tag t-r">⚠ ${Q().length} vente(s) pas encore envoyée(s) : attends le wifi avant de clôturer.</p>`:''}
 <table><tr><td>Fond de caisse</td><td class="n">${eur(s.fond)}</td></tr><tr><td>Ventes espèces</td><td class="n">${eur(t.especes)}</td></tr><tr><td><b>Espèces attendues</b></td><td class="n"><b>${eur(att)}</b></td></tr><tr><td>Total CB (appli)</td><td class="n">${eur(t.cb)}</td></tr><tr><td>Offerts</td><td class="n">${t.offert_nb||0}</td></tr></table>
 ${champNom('bvNomC')}<label for="bvEsp">Espèces comptées dans la caisse (total €)</label><input id="bvEsp" type="number" inputmode="decimal" step="0.01">
 <label for="bvTpe">Total du ticket de fin de journée TPE (€)</label><input id="bvTpe" type="number" inputmode="decimal" step="0.01">
 <label for="bvCom">Commentaire (facultatif)</label><input id="bvCom">
 <div class="row" style="margin-top:14px"><button type="button" class="alt" id="bvBack">Retour</button><button type="button" id="bvDo">Clôturer</button></div></div>`;
 g('bvBox').onclick=null;lierNom('bvNomC');g('bvBack').onclick=()=>{ecran='home';caisse()};
 g('bvDo').onclick=async()=>{if(Q().length&&!confirm('Des ventes ne sont pas encore envoyées. Clôturer quand même ?'))return;const n=x=>String(g(x).value).replace(',','.');if(n('bvEsp')===''||n('bvTpe')==='')return T('Remplis les deux totaux');if(!lireNom('bvNomC'))return T('Écris ton prénom');
  await sync();const j=await call('api_bv_cloturer',{p:{session_id:s.id,especes_comptees:+n('bvEsp'),cb_tpe:+n('bvTpe'),commentaire:g('bvCom').value,vendeur}});if(!j)return;if(!j.ok)return T(j.erreur);
  await charger();recap(j.recap,'bvBox')}}

function recap(r,box){const m=r.par_mode||{},e=r.evenement||{},ec=x=>`<b style="color:${Math.abs(+x)<0.005?'var(--ok)':'var(--red)'}">${(+x>0?'+':'')+eur(x)}</b>`;
 g(box).innerHTML=`<div class="card" id="bvRecap"><h2>Récapitulatif de caisse</h2>
 <p><b>${E(e.type)}${e.adversaire?' – '+E(e.adversaire):e.libelle?' – '+E(e.libelle):''}</b> · ${E(new Date(e.date).toLocaleDateString('fr-FR'))} · saison ${E(e.saison)}<br><span class="muted">Ouverte par ${E(r.ouverte_par)} à ${E(new Date(r.ouverte_le).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'}))}${r.cloturee_le?` · clôturée par ${E(r.cloturee_par)} à ${E(new Date(r.cloturee_le).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'}))}`:''}</span></p>
 <table><tr><th>Espèces</th><th class="n"></th></tr><tr><td>Fond de caisse</td><td class="n">${eur(r.fond)}</td></tr><tr><td>Ventes espèces (${m.nb_especes||0})</td><td class="n">${eur(m.especes)}</td></tr><tr><td>Attendu</td><td class="n">${eur(r.especes_attendues??(+r.fond+ +m.especes))}</td></tr>${r.especes_comptees!=null?`<tr><td>Compté</td><td class="n">${eur(r.especes_comptees)}</td></tr><tr><td>Écart</td><td class="n">${ec(r.ecart_especes)}</td></tr>`:''}
 <tr><th>Carte bancaire</th><th></th></tr><tr><td>Ventes CB (${m.nb_cb||0})</td><td class="n">${eur(m.cb)}</td></tr>${r.cb_tpe!=null?`<tr><td>Ticket TPE</td><td class="n">${eur(r.cb_tpe)}</td></tr><tr><td>Écart</td><td class="n">${ec(r.ecart_cb)}</td></tr>`:''}
 <tr><th>Total encaissé</th><th class="n">${eur(+m.especes+ +m.cb)}</th></tr>
 <tr><td>Offerts (Staff ${m.offert_staff||0} · Joueurs ${m.offert_joueur||0})</td><td class="n">${m.offert_nb||0} · coût ${eur(m.offert_valeur)}</td></tr><tr><td>Ventes annulées</td><td class="n">${m.annulees||0}</td></tr></table>
 <h3>Produits</h3><table>${(r.produits||[]).map(p=>`<tr><td>${E(p.nom)}</td><td class="n">${p.qte}</td><td class="n">${p.montant!=null?eur(p.montant):'—'}</td></tr>`).join('')||'<tr><td class="muted">Aucune vente</td></tr>'}</table>
 <h3>Vendeurs</h3><table>${(r.vendeurs||[]).map(v=>`<tr><td>${E(v.vendeur)}</td><td class="n">${v.nb} vente(s)</td><td class="n">${eur(v.montant)}</td></tr>`).join('')}</table>
 ${r.commentaire?`<p>Commentaire : ${E(r.commentaire)}</p>`:''}
 <div class="row noprint" style="margin-top:14px"><button type="button" id="bvPrint">🖨 Imprimer / PDF</button>${box==='bvBox'?'<button type="button" class="alt" id="bvNew">Nouvelle caisse</button>':''}</div></div>`;
 g('bvPrint').onclick=()=>{document.body.classList.add('bvprinting');print();setTimeout(()=>document.body.classList.remove('bvprinting'),500)};
 if(g('bvNew'))g('bvNew').onclick=()=>{ecran='home';caisse()}}

/* ---------- gestion (responsables) ---------- */
let onglet='produits',editP=null,photoP=null;
function reduire(f){return new Promise((ok,ko)=>{const r=new FileReader();r.onerror=ko;r.onload=()=>{const im=new Image();im.onerror=ko;im.onload=()=>{const c=Math.min(im.width,im.height),t=400,cv=document.createElement('canvas');cv.width=cv.height=t;
 cv.getContext('2d').drawImage(im,(im.width-c)/2,(im.height-c)/2,c,c,0,0,t,t);ok(cv.toDataURL('image/jpeg',0.75))};im.src=r.result};r.readAsDataURL(f)})}
function gestion(){const B=g('bvgBox');
 if(!D.resp){B.innerHTML='<div class="card bvcard"><h2>Gestion de la buvette</h2><p>Réservée aux comptes administrateurs.</p></div>';return}
 const tabs=[['produits','Produits'],['categories','Catégories'],['vendeurs','Prénoms'],['ventes','Ventes en cours'],['caisses','Caisses']];
 B.innerHTML=`<div class="bvbar">${tabs.map(([k,l])=>`<button type="button" class="${onglet===k?'':'alt'}" data-o="${k}">${l}</button>`).join('')}</div><div id="bvgIn"></div>`;
 B.onclick=e=>{const b=e.target.closest('button');if(!b)return;if(b.dataset.o){onglet=b.dataset.o;editP=null;return gestion()}};
 ({produits:gProduits,categories:gCats,vendeurs:gVend,ventes:gVentes,caisses:gCaisses})[onglet]()}
async function save(fn,args,msg){const j=await call(fn,args);if(!j)return false;if(!j.ok){T(j.erreur);if(j.code==='droits'){await charger();gestion()}return false}T(msg);await charger();gestion();return j}
const catNom=id=>((D.categories||[]).find(c=>c.id===id)||{}).nom||'—';
function gProduits(){const p=editP?D.produits.find(x=>x.id===editP)||{}:{},cats=D.categories||[];
 g('bvgIn').innerHTML=`<div class="card"><h3>${editP?'Modifier':'Nouveau produit'}</h3><div class="grid">
 <div><label for="pN">Nom</label><input id="pN" value="${E(p.nom||'')}"></div>
 <div><label for="pC">Catégorie</label><select id="pC"><option value="">—</option>${cats.map(c=>`<option value="${c.id}"${c.id===p.categorie_id?' selected':''}>${E(c.nom)}</option>`).join('')}</select></div>
 <div><label for="pV">Prix de vente (€)</label><input id="pV" type="number" step="0.01" inputmode="decimal" value="${E(p.prix_vente??'')}"></div>
 <div><label for="pA">Prix d'achat (€)</label><input id="pA" type="number" step="0.01" inputmode="decimal" value="${E(p.prix_achat??'')}"></div>
 ${editP?'':`<div><label for="pS">Stock de départ</label><input id="pS" type="number" inputmode="numeric" value="0"></div>`}
 <div><label for="pT">Alerte stock bas à</label><input id="pT" type="number" inputmode="numeric" value="${E(p.seuil??0)}"></div>
 <div><label for="pO">Ordre d'affichage</label><input id="pO" type="number" inputmode="numeric" value="${E(p.ordre??0)}"></div>
 <div><label for="pF">Photo</label><div class="row">${p.photo?`<img class="bvph" id="pImg" src="${E(p.photo)}" alt="">`:'<img class="bvph" id="pImg" alt="" hidden>'}<input id="pF" type="file" accept="image/*"></div></div>
 <label class="chk"><input type="checkbox" id="pX"${p.actif===false?'':' checked'}> Actif (visible en caisse)</label></div>
 <div class="row" style="margin-top:10px"><button type="button" id="pOk">Enregistrer</button>${editP?'<button type="button" class="alt" id="pNew">Annuler</button>':''}</div></div>
 <div class="card"><div class="scroll"><table class="stack"><thead><tr><th>Produit</th><th>Catégorie</th><th class="n">Vente</th><th class="n">Achat</th><th class="n">Stock</th><th>État</th><th></th></tr></thead><tbody>
 ${(D.produits||[]).map(x=>`<tr><td>${x.photo?`<img class="bvph" style="width:44px;height:44px;vertical-align:middle;margin-right:6px" src="${E(x.photo)}" alt="">`:''}<b>${E(x.nom)}</b></td><td>${E(catNom(x.categorie_id))}</td><td class="n">${eur(x.prix_vente)}</td><td class="n">${eur(x.prix_achat)}</td><td class="n">${x.stock<=x.seuil&&x.seuil>0?`<span class="tag t-r">${x.stock}</span>`:x.stock}</td><td>${x.actif?'<span class="tag t-o">Actif</span>':'<span class="tag">Inactif</span>'}</td><td><div class="acts"><button type="button" class="alt" data-e="${x.id}">Modifier</button><button type="button" class="alt" data-d="${x.id}">Supprimer</button></div></td></tr>`).join('')||'<tr><td class="muted">Aucun produit pour l\'instant.</td></tr>'}
 </tbody></table></div><p class="muted">Un produit déjà vendu n'est jamais supprimé : il passe en « Inactif ».</p></div>`;
 g('pOk').onclick=()=>save('api_bv_produit',{p:{id:editP||'',nom:g('pN').value,categorie_id:g('pC').value,prix_vente:g('pV').value,prix_achat:g('pA').value,stock:g('pS')?g('pS').value:'',seuil:g('pT').value,ordre:g('pO').value,actif:g('pX').checked,...(photoP!==null?{photo:photoP}:{})}},'Produit enregistré').then(r=>{if(r)editP=null});
 photoP=null;g('pF').onchange=async()=>{const f=g('pF').files[0];if(!f)return;try{photoP=await reduire(f);g('pImg').src=photoP;g('pImg').hidden=false}catch(e){T('Image illisible')}};
 if(g('pNew'))g('pNew').onclick=()=>{editP=null;gestion()};
 g('bvgIn').onclick=async e=>{const b=e.target.closest('button');if(!b)return;if(b.dataset.e){editP=+b.dataset.e;gestion();scrollTo(0,0)}if(b.dataset.d&&confirm('Supprimer ce produit ?'))save('api_bv_produit_suppr',{p_id:+b.dataset.d},'Fait')}}
function gCats(){g('bvgIn').innerHTML=`<div class="card"><h3>Catégories</h3><div class="row"><input id="cN" placeholder="Nouvelle catégorie (ex. Boissons)"><button type="button" id="cOk">Ajouter</button></div>
 <ul class="vl">${(D.categories||[]).map(c=>`<li><b>${E(c.nom)}</b> ${c.actif?'':'<span class="tag">Inactive</span>'} <span class="acts" style="float:right"><button type="button" class="alt" data-r="${c.id}">Renommer</button><button type="button" class="alt" data-t="${c.id}">${c.actif?'Désactiver':'Réactiver'}</button></span></li>`).join('')}</ul></div>`;
 g('cOk').onclick=()=>save('api_bv_categorie',{p:{nom:g('cN').value,ordre:(D.categories||[]).length}},'Catégorie ajoutée');
 g('bvgIn').onclick=e=>{const b=e.target.closest('button');if(!b)return;const c=(D.categories||[]).find(x=>x.id===+(b.dataset.r||b.dataset.t));if(!c)return;
  if(b.dataset.r){const n=prompt('Nouveau nom',c.nom);if(n)save('api_bv_categorie',{p:{id:c.id,nom:n}},'Renommée')}else save('api_bv_categorie',{p:{id:c.id,nom:c.nom,actif:!c.actif}},'Fait')}}
function gVend(){g('bvgIn').innerHTML=`<div class="card"><h3>Prénoms des vendeurs</h3><div class="row"><input id="vN" placeholder="Prénom"><button type="button" id="vOk">Ajouter</button></div>
 <ul class="vl">${(D.vendeurs||[]).map(v=>`<li><b>${E(v.prenom)}</b> ${v.actif?'':'<span class="tag">Retiré</span>'} <span class="acts" style="float:right"><button type="button" class="alt" data-t="${v.id}">${v.actif?'Retirer':'Remettre'}</button></span></li>`).join('')}</ul><p class="muted">Ces prénoms sont proposés automatiquement aux vendeurs quand ils écrivent leur prénom.</p></div>`;
 g('vOk').onclick=()=>save('api_bv_vendeur',{p:{prenom:g('vN').value}},'Prénom ajouté');
 g('bvgIn').onclick=e=>{const b=e.target.closest('[data-t]');if(!b)return;const v=D.vendeurs.find(x=>x.id===+b.dataset.t);save('api_bv_vendeur',{p:{id:v.id,prenom:v.prenom,actif:!v.actif}},'Fait')}}
const MODE={especes:'Espèces',cb:'CB',offert:'Offert'};
function gVentes(){if(!D.session){g('bvgIn').innerHTML='<div class="card"><p class="muted">Aucune caisse ouverte.</p></div>';return}
 g('bvgIn').innerHTML=`<div class="card"><h3>Ventes de la caisse en cours</h3><ul class="vl">${(D.ventes||[]).map(v=>`<li${v.annulee?' style="opacity:.55"':''}><b>${E(new Date(v.vendue_le).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'}))}</b> · ${E(v.vendeur)} · ${MODE[v.mode]}${v.mode==='offert'?' ('+E(v.beneficiaire_type)+(v.beneficiaire_nom?' '+E(v.beneficiaire_nom):'')+')':''} · <b>${eur(v.total)}</b><br><span class="muted">${(v.lignes||[]).map(l=>l.qte+'× '+E(l.nom)).join(', ')}</span>
 ${v.annulee?`<br><span class="tag t-r">Annulée</span> <span class="muted">${E(v.motif_annulation)} – ${E(v.annulee_par)}</span>`:`<span class="acts" style="float:right"><button type="button" class="alt" data-x="${v.id}">Annuler</button></span>`}</li>`).join('')||'<li class="muted">Aucune vente.</li>'}</ul></div>`;
 g('bvgIn').onclick=e=>{const b=e.target.closest('[data-x]');if(!b)return;const m=(prompt('Motif de l\'annulation ?')||'').trim();if(!m)return;save('api_bv_annuler',{p_id:b.dataset.x,p_motif:m,p_vendeur:''},'Vente annulée')}}
function gCaisses(){g('bvgIn').innerHTML=`<div class="card"><h3>Dernières caisses</h3><ul class="vl">${(D.sessions_recentes||[]).map(s=>`<li><b>${E(new Date(s.date).toLocaleDateString('fr-FR'))}</b> · ${E(s.evenement)} ${s.statut==='ouverte'?'<span class="tag t-a">Ouverte</span>':''}<span class="acts" style="float:right"><button type="button" class="alt" data-s="${s.id}">Récapitulatif</button></span></li>`).join('')||'<li class="muted">Aucune caisse.</li>'}</ul></div><div id="bvgRec"></div>`;
 g('bvgIn').onclick=async e=>{const b=e.target.closest('[data-s]');if(!b)return;const j=await call('api_bv_recap',{p_session:+b.dataset.s});if(j&&j.ok)recap(j.recap,'bvgRec');else if(j)T(j.erreur)}}

/* ---------- administration : code responsable ---------- */
window.bvParams=function(){};
const h=location.hash.slice(1);if((h==='buvette'||h==='bv-gestion')&&LM.READY)window.bvRender(h);
})();
