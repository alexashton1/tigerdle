/* Shared site chrome: header nav + footer + subscribe widget + toast helper.
   Include after supabase-client.js. Call renderChrome('home'|'play'|'blog') at top of <body>. */

/* Original shield badge, not the Hull City AFC crest, a standalone mark
   in the club's colours. Swap this <svg> out for a real crest file if/when
   you want to use official artwork instead. */
const BADGE_SVG = `
<svg class="badge-svg" viewBox="0 0 64 76" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <defs>
    <clipPath id="shieldClip"><path d="M32 2 L59 11 L59 39 C59 58 47 69 32 74 C17 69 5 58 5 39 L5 11 Z"/></clipPath>
  </defs>
  <path d="M32 2 L59 11 L59 39 C59 58 47 69 32 74 C17 69 5 58 5 39 L5 11 Z" fill="#f5a300"/>
  <g clip-path="url(#shieldClip)">
    <rect x="-10" y="44" width="90" height="8" fill="#14110d" transform="rotate(-18 32 40)"/>
    <rect x="-10" y="60" width="90" height="8" fill="#14110d" transform="rotate(-18 32 40)"/>
  </g>
  <text x="32" y="30" text-anchor="middle" font-family="Anton, sans-serif" font-size="24" fill="#14110d">T</text>
  <path d="M32 2 L59 11 L59 39 C59 58 47 69 32 74 C17 69 5 58 5 39 L5 11 Z" fill="none" stroke="#14110d" stroke-width="2"/>
</svg>`;

/* Makes the site installable to a phone's home screen. Runs once,
   on every page, via chrome.js. No need to edit each page's <head>
   individually. Uses the same origin as everything else, so a
   signed-in session carries over into the installed app exactly like
   opening the site in a normal tab. There's no separate storage for
   an "installed" version, it's the same website either way. */
(function setupPWA(){
  if(!document.querySelector('link[rel="manifest"]')){
    const manifestLink = document.createElement('link');
    manifestLink.rel = 'manifest';
    manifestLink.href = 'manifest.json';
    document.head.appendChild(manifestLink);
  }
  if(!document.querySelector('meta[name="theme-color"]')){
    const themeColor = document.createElement('meta');
    themeColor.name = 'theme-color';
    themeColor.content = '#f5a300';
    document.head.appendChild(themeColor);
  }
  // iOS Safari ignores the manifest for "Add to Home Screen" and needs
  // these specific tags instead.
  if(!document.querySelector('meta[name="apple-mobile-web-app-capable"]')){
    const cap = document.createElement('meta');
    cap.name = 'apple-mobile-web-app-capable';
    cap.content = 'yes';
    document.head.appendChild(cap);
  }
  if(!document.querySelector('meta[name="apple-mobile-web-app-title"]')){
    const title = document.createElement('meta');
    title.name = 'apple-mobile-web-app-title';
    title.content = 'TIGERDLE';
    document.head.appendChild(title);
  }
  if('serviceWorker' in navigator){
    navigator.serviceWorker.register('sw.js').catch(()=>{ /* not critical if this fails */ });
  }
})();

function renderChrome(current){
  const header = document.getElementById('site-header');
  if(header){
    header.innerHTML = `
      <div class="stripe-bar"></div>
      <div class="wrap">
        <div class="brandrow">
          <a class="brand" href="index.html">
            ${BADGE_SVG}
            <span class="logo">TIGERDLE</span>
          </a>
          <div class="nav-group">
            <nav class="site-nav">
              <a href="index.html" ${current==='home'?'class="current"':''}>Home</a>
              <a href="game.html" ${current==='play'?'class="current"':''}>Play</a>
              <a href="blog.html" ${current==='blog'?'class="current"':''}>Blog</a>
              <a href="predictor.html" class="auth-nav-link${current==='predictor'?' current':''}" id="nav-predictor-link">Predictor</a>
              <a href="leagues.html" class="auth-nav-link${current==='leagues'?' current':''}" id="nav-leagues-link">Leagues</a>
            </nav>
            <a href="account.html" class="account-btn ${current==='account'?'current':''}" id="header-account-btn">👤 Sign In</a>
          </div>
        </div>
      </div>`;
    updateAccountButtonAuthState();
  }
  const footer = document.getElementById('site-footer');
  if(footer){
    const socialLinks = [];
    if(typeof X_URL !== 'undefined' && X_URL && !X_URL.includes('YOUR-USERNAME')){
      socialLinks.push(`<a class="social-icon" href="${X_URL}" target="_blank" rel="noopener" aria-label="Follow on X" title="Follow on X">𝕏</a>`);
    }
    if(typeof REDDIT_URL !== 'undefined' && REDDIT_URL && !REDDIT_URL.includes('YOUR-USERNAME')){
      socialLinks.push(`<a class="social-icon" href="${REDDIT_URL}" target="_blank" rel="noopener" aria-label="Join us on Reddit" title="Join us on Reddit">r/</a>`);
    }
    footer.innerHTML = `
      <div class="wrap">
        <div class="subscribe-box" id="subscribe-box">
          <h3>Get new puzzles &amp; posts by email</h3>
          <p>One email when there's something new: a blog post, a fresh goal-guess puzzle, nothing else.</p>
          <div class="subscribe-row">
            <input type="email" id="sub-email" placeholder="you@email.com" autocomplete="email">
            <button id="sub-btn">Subscribe</button>
          </div>
          <div class="subscribe-msg" id="sub-msg"></div>
        </div>
        ${socialLinks.length ? `<div class="social-row">${socialLinks.join('')}</div>` : ''}
        <footer class="sitefoot">
          TIGERDLE · built for the amber &amp; black · not affiliated with Hull City AFC
          <br>
          <a href="about.html" class="footer-link">About &amp; FAQ</a> ·
          <a href="privacy.html" class="footer-link">Privacy</a> ·
          <a href="terms.html" class="footer-link">Terms</a>
          ${typeof TIP_JAR_URL !== 'undefined' && TIP_JAR_URL && !TIP_JAR_URL.includes('YOUR-USERNAME')
            ? `<br><a class="tipjar-link" href="${TIP_JAR_URL}" target="_blank" rel="noopener">☕ Buy me a coffee</a>`
            : ''}
        </footer>
      </div>`;
    document.getElementById('sub-btn').addEventListener('click', subscribeSubmit);
    document.getElementById('sub-email').addEventListener('keydown', e=>{ if(e.key==='Enter') subscribeSubmit(); });
  }
  if(!document.getElementById('toast')){
    const t = document.createElement('div');
    t.className='toast'; t.id='toast';
    document.body.appendChild(t);
  }
}

/* If someone's already signed in, from a magic-link click on ANY page,
   not just this one, this shows it in the header immediately. Supabase
   persists sessions in localStorage by default, shared across every
   page on the same domain, so this isn't re-checking a login each time,
   just surfacing a session that's already there. */
async function updateAccountButtonAuthState(){
  const btn = document.getElementById('header-account-btn');
  if(!btn || typeof sb === 'undefined' || !sb.auth) return;

  function revealAuthNavLinks(animate){
    document.querySelectorAll('.auth-nav-link').forEach(link=>{
      if(link.classList.contains('visible')) return; // already shown, never re-animate
      link.classList.add('visible');
      if(animate) link.classList.add('animate-in');
    });
  }
  function markSignedIn(user){
    const label = user.email ? user.email.split('@')[0] : 'Account';
    btn.textContent = `👤 ${label}`;
    btn.title = `Signed in as ${user.email}`;
    btn.classList.add('signed-in');
  }

  // A single source of truth for this, rather than a separate getSession()
  // call racing against this listener. onAuthStateChange reliably fires
  // once on setup with whatever the current session is (event
  // 'INITIAL_SESSION' if signed in, or none if not), then again for any
  // real sign-in that happens afterward. Mixing two separate async paths
  // here was the likely cause of the nav links being fine on the page
  // someone signed in on, but not reliably showing after navigating on to
  // a page with more of its own async work competing at load time.
  function markSignedOut(){
    btn.textContent = '👤 Sign In';
    btn.title = '';
    btn.classList.remove('signed-in');
    document.querySelectorAll('.auth-nav-link').forEach(link=>{
      link.classList.remove('visible', 'animate-in');
    });
  }

  sb.auth.onAuthStateChange((event, session)=>{
    if(!session?.user){
      if(event === 'SIGNED_OUT') markSignedOut();
      return;
    }
    markSignedIn(session.user);
    // Only the live SIGNED_IN event is someone watching it happen,
    // arriving on a page already signed in shouldn't animate anything.
    revealAuthNavLinks(event === 'SIGNED_IN');
    checkForNewAchievements(session.user.id);
  });
}

// Builds its own toast element rather than relying on one already being
// on the page. Not every page has one, and achievements can genuinely
// be earned from any of them (a game, a prediction, joining a league),
// so this needs to work everywhere without assuming anything about
// what markup that particular page happens to already have.
function showAchievementToast(icon, name, tier){
  const el = getOrCreateAchievementToastEl();
  const tierLabel = tier.charAt(0).toUpperCase() + tier.slice(1);
  el.querySelector('#achievement-toast-content').innerHTML = `<span style="font-size:26px;">${icon}</span><span style="font-family:'Inter',sans-serif;"><span style="font-family:var(--mono); font-size:9.5px; color:var(--amber-soft); text-transform:uppercase; letter-spacing:.05em; display:block;">Achievement unlocked: ${tierLabel}</span><span style="color:var(--paper); font-size:14px; font-weight:600;">${name}</span></span>`;
  animateAchievementToast(el);
}
function showAchievementSummaryToast(count){
  const el = getOrCreateAchievementToastEl();
  el.querySelector('#achievement-toast-content').innerHTML = `<span style="font-size:26px;">🎉</span><span style="font-family:'Inter',sans-serif;"><span style="font-family:var(--mono); font-size:9.5px; color:var(--amber-soft); text-transform:uppercase; letter-spacing:.05em; display:block;">${count} achievements unlocked</span><span style="color:var(--paper); font-size:14px; font-weight:600;">See them all on your Achievements page</span></span>`;
  animateAchievementToast(el);
}
function getOrCreateAchievementToastEl(){
  let el = document.getElementById('achievement-toast');
  if(!el){
    el = document.createElement('div');
    el.id = 'achievement-toast';
    el.style.cssText = 'position:fixed; bottom:24px; left:50%; transform:translateX(-50%) translateY(120%); z-index:200; background:var(--ink-2); border:1px solid var(--amber); border-radius:12px; padding:12px 34px 12px 20px; display:flex; align-items:center; gap:12px; box-shadow:0 8px 28px rgba(0,0,0,0.5); transition:transform .35s ease; max-width:90vw; cursor:pointer;';
    el.innerHTML = `
      <div id="achievement-toast-content" style="display:flex; align-items:center; gap:12px;"></div>
      <span id="achievement-toast-close" style="position:absolute; top:6px; right:9px; font-family:var(--mono); font-size:14px; color:var(--paper-dim); line-height:1; cursor:pointer; padding:2px;">&times;</span>
    `;
    // Clicking anywhere on the toast dismisses it early, not just the
    // close button specifically. The whole thing is an obvious target.
    el.addEventListener('click', dismissAchievementToast);
    document.body.appendChild(el);
  }
  return el;
}
function dismissAchievementToast(){
  const el = document.getElementById('achievement-toast');
  if(!el) return;
  el.style.transform = 'translateX(-50%) translateY(120%)';
  clearTimeout(animateAchievementToast._t);
}
function animateAchievementToast(el){
  requestAnimationFrame(()=>{ el.style.transform = 'translateX(-50%) translateY(0)'; });
  clearTimeout(animateAchievementToast._t);
  animateAchievementToast._t = setTimeout(()=>{ el.style.transform = 'translateX(-50%) translateY(120%)'; }, 4200);
}

// Runs on every page while signed in. Achievements can be earned from
// any of them, so notification can't be tied to just one place (like
// only the Achievements page itself, which someone might rarely visit).
async function checkForNewAchievements(userId){
  try{
    await sb.rpc('calculate_achievements', { uid: userId });
    const { data: unseen } = await sb.from('user_achievements').select('achievement_key').eq('user_id', userId).eq('seen', false);
    if(!unseen || !unseen.length) return;

    const keys = unseen.map(u => u.achievement_key);
    // Marked seen immediately, before any toast is shown, not after.
    // Showing them first and marking seen last left a window where
    // navigating to a new page quickly could re-fetch the same
    // still-unseen rows and show them a second time. This closes that
    // gap down to a single database round trip instead of the whole
    // staggered toast sequence.
    await sb.from('user_achievements').update({ seen: true }).eq('user_id', userId).in('achievement_key', keys);

    const { data: defs } = await sb.from('achievement_definitions').select('*').in('key', keys);
    const sorted = (defs||[]).sort((a,b)=>a.sort_order-b.sort_order);
    // More than a few at once, most likely a first login after a
    // backfill catches someone up on a lot of history at once, reads
    // better as one summary than a long, slow drip of individual
    // toasts stacking up over the better part of a minute.
    if(sorted.length > 3){
      showAchievementSummaryToast(sorted.length);
    } else {
      sorted.forEach((d, i)=>{
        setTimeout(()=> showAchievementToast(d.icon, d.name, d.tier), i * 4500);
      });
    }
  }catch(e){ /* not critical, worst case, it shows next page load instead */ }
}

async function subscribeSubmit(){
  const input = document.getElementById('sub-email');
  const msg = document.getElementById('sub-msg');
  const email = (input.value||'').trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){ msg.textContent = 'Enter a valid email address.'; return; }
  msg.textContent = 'Subscribing…';
  try{
    const { error } = await sb.from('subscribers').insert({ email });
    if(error){
      if(String(error.message||'').toLowerCase().includes('duplicate')){
        msg.textContent = "You're already subscribed \u2014 nice.";
      } else {
        msg.textContent = 'Could not subscribe right now, try again shortly.';
      }
    } else {
      msg.textContent = "You're in. Look out for the next post.";
      input.value = '';
    }
  } catch(e){
    msg.textContent = 'Could not reach the server \u2014 try again shortly.';
  }
}

function toast(message){
  const t = document.getElementById('toast');
  if(!t) return;
  t.textContent = message;
  t.classList.add('show');
  clearTimeout(toast._t);
  toast._t = setTimeout(()=>t.classList.remove('show'), 1800);
}
