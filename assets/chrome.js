/* Shared site chrome: header nav + footer + subscribe widget + toast helper.
   Include after supabase-client.js. Call renderChrome('home'|'play'|'blog') at top of <body>. */

/* Original shield badge — not the Hull City AFC crest, a standalone mark
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
          <nav class="site-nav">
            <a href="index.html" ${current==='home'?'class="current"':''}>Home</a>
            <a href="game.html" ${current==='play'?'class="current"':''}>Play</a>
            <a href="blog.html" ${current==='blog'?'class="current"':''}>Blog</a>
          </nav>
        </div>
      </div>`;
  }
  const footer = document.getElementById('site-footer');
  if(footer){
    footer.innerHTML = `
      <div class="wrap">
        <div class="subscribe-box" id="subscribe-box">
          <h3>Get new puzzles &amp; posts by email</h3>
          <p>One email when there's something new — a blog post, a fresh goal-guess puzzle, nothing else.</p>
          <div class="subscribe-row">
            <input type="email" id="sub-email" placeholder="you@email.com" autocomplete="email">
            <button id="sub-btn">Subscribe</button>
          </div>
          <div class="subscribe-msg" id="sub-msg"></div>
        </div>
        <footer class="sitefoot">
          TIGERDLE · built for the amber &amp; black · not affiliated with Hull City AFC
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
