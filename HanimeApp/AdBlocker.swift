import Foundation
import WebKit

// MARK: - 广告拦截
/// 原则：宁漏勿杀。只隐藏"名字里明确写着广告"的元素 + 广告联盟域名的资源；
/// 绝对不碰带 download / 下載 / 播放 / btn 之类的元素。
/// 强制跳转靠原生层拦截；下载类点击通过 hnapp:// 协议交给原生层接管。
enum AdBlocker {

    /// 广告 / 弹窗联盟域名关键词
    static let blockedHostKeywords: [String] = [
        "doubleclick", "googlesyndication", "googleadservices", "adservice.google",
        "adsystem", "adnxs", "rubiconproject", "pubmatic", "openx.net", "smartadserver",
        "criteo", "taboola", "outbrain", "mgid.", "revcontent", "zedo", "yieldmo",
        "popads", "popcash", "propellerads", "propellerpops", "clickadu", "exoclick",
        "juicyads", "trafficjunky", "adsterra", "hilltopads", "onclck", "bidswitch",
        "casalemedia", "moatads", "sharethrough", "teads", "adsrvr", "applovin",
        "unityads", "vungle", "ironsrc", "chartboost", "inmobi", "smaato",
        "tapjoy", "adtrue", "adnium", "tsyndicate", "trafficstars",
        "adspyglass", "popunder", "clickaine", "adcash", "betweendigital",
        "adfox", "adriver", "adcolony", "start.io"
    ]

    static func isAdURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty else { return false }
        let full = url.absoluteString.lowercased()
        for keyword in blockedHostKeywords where host.contains(keyword) || full.contains(keyword) {
            return true
        }
        return false
    }

    /// 注入到网页的脚本：拦弹窗 + 严格隐藏广告 + 隐藏网页自带底栏 + 下载点击接管
    static let bootstrapJS: String = ##"""
    (function () {
      if (window.__hnAppReady) { return; }
      window.__hnAppReady = true;

      var AD_HOST = /(doubleclick|googlesyndication|googleadservices|adservice\.google|adsystem|adnxs|rubiconproject|pubmatic|openx\.net|smartadserver|criteo|taboola|outbrain|mgid\.|revcontent|zedo|yieldmo|popads|popcash|propellerads|clickadu|exoclick|juicyads|trafficjunky|adsterra|hilltopads|onclck|bidswitch|casalemedia|moatads|sharethrough|teads|adsrvr|applovin|unityads|vungle|ironsrc|chartboost|inmobi|smaato|trafficstars|adspyglass|popunder|adcash|adfox|adriver)/i;

      // 白名单：凡是带这些字样（下载 / 播放 / 按钮）的元素绝对不动
      var SAFE = /(download|dl[\s_\-]|下載|下载|播放|play|btn|button|link|watch)/i;

      // 下载意图：用于把下载类点击交给原生层（比 SAFE 更严格，避免误转普通外链）
      var DL = /(^|[\s_\-])(download|下載|下载|dl)([\s_\-]|$)|下載|下载/i;

      // 记录"用户刚点的是不是下载/播放类元素"，这类触发的 window.open 放行
      var lastClickSafe = false;
      var safeTimer = null;

      function clickDesc(t) {
        var desc = "";
        if (!t) { return desc; }
        desc += " " + (t.innerText || t.textContent || "");
        var box = t.closest ? t.closest("a, button, div, li, td") : null;
        if (box) {
          desc += " " + (typeof box.className === "string" ? box.className : "");
          desc += " " + (box.getAttribute("href") || "");
        }
        return desc;
      }

      // 捕获阶段监听点击：标记下载/播放意图 + 把下载类站外链接转交原生层
      document.addEventListener("click", function (ev) {
        var t = null;
        try { t = ev.target; } catch (e) { return; }
        var desc = clickDesc(t);
        if (SAFE.test(desc)) {
          lastClickSafe = true;
          if (safeTimer) { clearTimeout(safeTimer); }
          safeTimer = setTimeout(function () { lastClickSafe = false; }, 1500);
        }

        // 站外"下载意图"链接：阻止默认行为，走 hnapp:// 让原生层接管
        var a = t && t.closest ? t.closest("a[href]") : null;
        if (!a) { return; }
        var href = a.getAttribute("href") || "";
        if (!href || href.charAt(0) === "#" || href.indexOf("javascript:") === 0) { return; }
        var u;
        try { u = new URL(href, location.href); } catch (e) { return; }
        if (!u.hostname) { return; }
        var isMedia = /\.(mp4|webm|mov|m4v|mkv|ts)(\?|#|$)/i.test(u.pathname + u.search);
        if (/hanime/i.test(u.hostname) || isMedia || !DL.test(desc)) { return; }
        try {
          ev.preventDefault();
          ev.stopPropagation();
          location.href = "hnapp://open?url=" + encodeURIComponent(u.href);
        } catch (e) {}
      }, true);

      // ---- 1) 弹窗：不放行任何真弹窗，改为当前页跳转让原生层接管 ----
      //     站内/媒体 → 直接跳（原生会自动转下载）；下载意图的站外页 → hnapp 标记
      window.open = function (url) {
        try {
          var u = new URL(url || "", location.href);
          if (AD_HOST.test(u.hostname)) { return null; }
          var sameSite = /hanime/i.test(u.hostname);
          var isMedia = /\.(mp4|webm|mov|m4v|mkv|ts)(\?|#|$)/i.test(u.pathname + u.search);
          if (sameSite || isMedia || lastClickSafe) {
            lastClickSafe = false;
            if (sameSite || isMedia) {
              location.href = u.href;
            } else {
              location.href = "hnapp://open?url=" + encodeURIComponent(u.href);
            }
          }
        } catch (e) { /* URL 非法/为空：拦掉 */ }
        return null;
      };

      function hide(el) {
        if (!el || el.__hnHidden) { return; }
        el.__hnHidden = 1;
        el.style.setProperty("display", "none", "important");
      }

      // ---- 2) 严格隐藏广告位（只查明确广告命名的容器 + 广告域名的 iframe/图片）----
      function sweepAds(root) {
        if (!root || !root.querySelectorAll) { return; }
        var nodes = root.querySelectorAll("iframe, ins, img, div, section, aside");
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (el.__hnHidden) { continue; }

          if (el.tagName === "IFRAME" || el.tagName === "IMG") {
            var src = el.src || el.getAttribute("data-src") || el.getAttribute("data-original") || "";
            if (src && AD_HOST.test(src)) { hide(el); }
            continue;
          }

          var idc = ((el.id || "") + " " + (typeof el.className === "string" ? el.className : "")).trim();
          if (!idc) { continue; }
          if (SAFE.test(idc)) { continue; }
          if (SAFE.test((el.innerText || "").slice(0, 60))) { continue; }
          var STRICT_AD = /(adsbygoogle|adsense|advertisement|advertisment|contentads|ad-banner|ad_banner|ad-slot|ad_slot|ad-unit|ad_unit|ad-container|ad_container|ad-wrapper|ad_wrapper|ad-box|ad_box|adframe|ad-frame|adsbox|ads-box|advert-box|advertbox|advert-container|popunder|popads|banner-ad|banner_ad|dfp-ad|google-ad|sponsor-ad|taboola|outbrain)/i;
          if (STRICT_AD.test(idc)) { hide(el); }
        }
      }

      // ---- 3) 只干掉"透明全屏广告层"（条件极严格，绝不误伤正常按钮）----
      function killHijackers() {
        var vw = window.innerWidth || 1;
        var vh = window.innerHeight || 1;
        var anchors = document.querySelectorAll("a[href]");
        for (var i = 0; i < anchors.length; i++) {
          var a = anchors[i];
          if (a.__hnChecked) { continue; }
          a.__hnChecked = 1;
          var href = a.getAttribute("href") || "";
          if (!href || href.charAt(0) === "#" || href.indexOf("javascript:") === 0) { continue; }
          var u;
          try { u = new URL(href, location.href); } catch (e) { continue; }
          if (/hanime/i.test(u.hostname)) { continue; }
          var cs = window.getComputedStyle(a);
          if (cs.position !== "fixed") { continue; }
          var z = parseInt(cs.zIndex, 10) || 0;
          if (z < 100) { continue; }
          var r = a.getBoundingClientRect();
          if (r.width * r.height < vw * vh * 0.5) { continue; }
          if ((a.innerText || "").trim()) { continue; }
          if (a.querySelector("img, svg, video, picture, i")) { continue; }
          hide(a);
        }
      }

      // ---- 4) 导航项定位（原生底栏调用，用网站自己的真实地址）----
      function cleanText(el) {
        return (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
      }

      function findNav(label) {
        var all = document.querySelectorAll("a, button, li, div, span");
        var best = null, bestLen = 999, bestW = 1e9;
        for (var i = 0; i < all.length; i++) {
          var t = cleanText(all[i]);
          if (!t || t.length > 14 || t.indexOf(label) === -1) { continue; }
          var w = all[i].getBoundingClientRect().width;
          if (t.length < bestLen || (t.length === bestLen && w < bestW)) {
            best = all[i]; bestLen = t.length; bestW = w;
          }
        }
        return best;
      }

      window.__hnNav = function (label) {
        var el = findNav(label);
        if (!el) { return ""; }
        var a = el.closest ? el.closest("a") : null;
        if (a && a.href) { return a.href; }
        try { el.click(); } catch (e) {}
        return "clicked";
      };

      // ---- 5) 隐藏网页自带底部导航：必须同时满足"贴底、矮、占满宽度"三条 ----
      function hideSiteNav() {
        if (window.__hnNavHidden) { return; }
        var el = findNav("本日排行");
        if (!el) { return; }
        var cur = el, guard = 0;
        while (cur && cur !== document.body && guard++ < 10) {
          var cs = window.getComputedStyle(cur);
          if (cs.position === "fixed" || cs.position === "sticky") {
            var r = cur.getBoundingClientRect();
            var vh = window.innerHeight || 1;
            var vw = window.innerWidth || 1;
            var nearBottom = r.bottom > vh - 40;
            var short = r.height > 20 && r.height < 140;
            var wide = r.width > vw * 0.8;
            if (nearBottom && short && wide) {
              cur.style.setProperty("display", "none", "important");
              window.__hnNavHidden = 1;
            }
            return;
          }
          cur = cur.parentElement;
        }
      }

      function run() {
        sweepAds(document);
        killHijackers();
        hideSiteNav();
      }

      var pending = false;
      function schedule() {
        if (pending) { return; }
        pending = true;
        setTimeout(function () { pending = false; run(); }, 400);
      }

      run();
      try {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      setTimeout(run, 800);
      setTimeout(run, 2000);
      setTimeout(run, 4000);
    })();
    """##
}
