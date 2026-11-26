// Boutique LMSTT : page toujours à jour quand le réseau est là, version en cache sinon.
const CACHE='lmstt-v23';
const FICHIERS=['./','./index.html','./logo.png','./icon-192.png','./icon-512.png','./manifest.webmanifest','./buvette.js?v=22'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(FICHIERS)));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==CACHE).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET'||u.origin!==location.origin)return; // la base Supabase n'est jamais mise en cache
  e.respondWith(fetch(e.request).then(r=>{const copie=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copie));return r})
    .catch(()=>caches.match(e.request).then(r=>r||caches.match('./index.html'))));
});
