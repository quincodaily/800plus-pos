// Lets the POS open without internet after one online visit. Never caches Supabase API calls.
const C='800plus-v1',LIB='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/dist/umd/supabase.js';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(async c=>{await c.addAll(['./','./index.html']);try{await c.put(LIB,await fetch(LIB,{mode:'no-cors'}))}catch(x){}}));self.skipWaiting()});
self.addEventListener('activate',e=>e.waitUntil(clients.claim()));
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);if(r.method!=='GET'||u.hostname.endsWith('supabase.co'))return;
 e.respondWith(fetch(r).then(x=>{const k=x.clone();caches.open(C).then(c=>c.put(r,k));return x}).catch(()=>caches.match(r).then(m=>m||caches.match('./index.html'))))});
