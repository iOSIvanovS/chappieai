(function () {
  var KEY = "chappie-lang";
  var supported = window.LANGS.map(function (l) { return l[0]; });

  function normalize(code) {
    if (!code) return null;
    var c = String(code).toLowerCase();
    if (c.indexOf("zh") === 0) return "zh-Hans";
    if (c.indexOf("pt") === 0) return "pt-BR";
    var base = c.split("-")[0];
    return supported.indexOf(base) >= 0 ? base : null;
  }

  function detect() {
    var fromUrl = normalize(new URLSearchParams(location.search).get("lang"));
    if (fromUrl) return fromUrl;
    try {
      var saved = localStorage.getItem(KEY);
      if (saved && supported.indexOf(saved) >= 0) return saved;
    } catch (e) {}
    var prefs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
    for (var i = 0; i < prefs.length; i++) {
      var n = normalize(prefs[i]);
      if (n) return n;
    }
    return "en";
  }

  function apply(lang) {
    var dict = window.I18N[lang] || window.I18N.en;
    var en = window.I18N.en;
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var k = el.getAttribute("data-i18n");
      el.textContent = dict[k] || en[k];
    });
    document.querySelectorAll("[data-i18n-aria]").forEach(function (el) {
      var k = el.getAttribute("data-i18n-aria");
      el.setAttribute("aria-label", dict[k] || en[k]);
    });
    document.title = dict.title || en.title;
    var meta = document.querySelector('meta[name="description"]');
    if (meta) meta.setAttribute("content", dict.desc || en.desc);
  }

  var select = document.getElementById("lang");
  window.LANGS.forEach(function (l) {
    var o = document.createElement("option");
    o.value = l[0];
    o.textContent = l[1];
    select.appendChild(o);
  });

  var current = detect();
  select.value = current;
  if (current !== "en") apply(current);

  select.addEventListener("change", function () {
    try { localStorage.setItem(KEY, select.value); } catch (e) {}
    apply(select.value);
  });

  // Screenshot viewer on a native <dialog>: Esc and focus trapping come for free.
  var dlg = document.getElementById("lb");
  var img = document.getElementById("lbImg");
  var shots = Array.prototype.slice.call(document.querySelectorAll(".shot"));
  var idx = 0;

  function show(i) {
    idx = (i + shots.length) % shots.length;
    var src = shots[idx].querySelector("img");
    img.src = src.getAttribute("src");
    img.alt = src.getAttribute("alt");
  }
  shots.forEach(function (b, i) {
    b.addEventListener("click", function () { show(i); dlg.showModal(); });
  });
  document.getElementById("lbClose").addEventListener("click", function () { dlg.close(); });
  document.getElementById("lbPrev").addEventListener("click", function () { show(idx - 1); });
  document.getElementById("lbNext").addEventListener("click", function () { show(idx + 1); });
  dlg.addEventListener("click", function (e) { if (e.target === dlg) dlg.close(); });
  dlg.addEventListener("keydown", function (e) {
    var rtl = document.documentElement.dir === "rtl";
    if (e.key === "ArrowLeft") show(idx + (rtl ? 1 : -1));
    if (e.key === "ArrowRight") show(idx + (rtl ? -1 : 1));
  });
})();
