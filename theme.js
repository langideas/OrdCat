// OrdCat site: theme (auto / light / dark) + language (zh / en), remembered in localStorage.
(function(){
  var d=document.documentElement, ls=window.localStorage;
  var t=ls.getItem('oc-theme')||'auto';
  function applyTheme(v){t=v;ls.setItem('oc-theme',v);
    var dark=v==='dark'||(v==='auto'&&matchMedia('(prefers-color-scheme: dark)').matches);
    d.setAttribute('data-theme',dark?'dark':'light');d.setAttribute('data-theme-pref',v);
    var b=document.getElementById('themeBtn');if(b)b.textContent={auto:'◐',light:'☀︎',dark:'☾'}[v];
    if(b)b.title={auto:'Auto',light:'Light',dark:'Dark'}[v];}
  applyTheme(t);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change',function(){if(t==='auto')applyTheme('auto')});
  window.ocCycleTheme=function(){applyTheme({auto:'light',light:'dark',dark:'auto'}[t])};
  var lang=ls.getItem('oc-lang')||((navigator.language||'zh').toLowerCase().indexOf('zh')===0?'zh':'en');
  function applyLang(v){lang=v;ls.setItem('oc-lang',v);d.setAttribute('lang',v==='zh'?'zh-CN':'en');d.setAttribute('data-lang',v);
    var dict=window.OC_I18N||{};
    document.querySelectorAll('[data-i]').forEach(function(el){var k=el.getAttribute('data-i');var e=dict[k];if(!e)return;
      if(!el.hasAttribute('data-zh'))el.setAttribute('data-zh',el.innerHTML);
      el.innerHTML=v==='zh'?el.getAttribute('data-zh'):e});
    document.querySelectorAll('[data-i-alt]').forEach(function(el){var k=el.getAttribute('data-i-alt');var e=dict[k];if(!e)return;
      if(!el.hasAttribute('data-zh-alt'))el.setAttribute('data-zh-alt',el.getAttribute('alt')||'');
      el.setAttribute('alt',v==='zh'?el.getAttribute('data-zh-alt'):e)});
    if(dict.__title){if(!d.hasAttribute('data-zh-title'))d.setAttribute('data-zh-title',document.title);document.title=v==='zh'?d.getAttribute('data-zh-title'):dict.__title}
    var md=document.querySelector('meta[name=description]');if(md&&dict.__desc){if(!md.hasAttribute('data-zh'))md.setAttribute('data-zh',md.content);md.content=v==='zh'?md.getAttribute('data-zh'):dict.__desc}
    var b=document.getElementById('langBtn');if(b)b.textContent=v==='zh'?'EN':'中文';
    document.dispatchEvent(new CustomEvent('oc-lang',{detail:v}));}
  d.setAttribute('data-lang',lang);
  window.ocToggleLang=function(){applyLang(lang==='zh'?'en':'zh')};
  window.ocLang=function(){return lang};
  document.addEventListener('DOMContentLoaded',function(){applyTheme(t);applyLang(lang)});
})();

// Nav logo eyes blink like the cat (2.2–6 s apart, 160 ms, sometimes twice).
(function(){
  function go(){
    var e=document.querySelector('.brand img.eyes');if(!e||!e.animate)return;
    if(window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches)return;
    function once(){e.animate([{transform:'scaleY(1)'},{transform:'scaleY(.15)'},{transform:'scaleY(1)'}],{duration:160,easing:'ease-in-out'})}
    (function sch(){setTimeout(function(){once();if(Math.random()<.25)setTimeout(once,260);sch()},2200+Math.random()*3800)})();
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',go);else go();
})();
