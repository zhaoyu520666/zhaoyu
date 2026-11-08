import Foundation
import WebKit

// MARK: - 广告拦截
/// 原则：宁漏勿杀。只隐藏"名字里明确写着广告"的元素 + 广告联盟域名的资源；
/// 绝对不碰带 download / 下載 / 播放 / btn 之类的元素（上一版把站内的下载链接和播放按钮误藏了）。
/// 强制跳转主要靠原生层拦截，不靠大面积隐藏。
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

    /// 注入到网页的脚本：拦弹窗 + 严格隐藏广告 + 隐藏网页自带底栏（App 原生底栏代替）
    static let bootstrapJS: String = ##"""
    (function () {
      if (window.__hnAppReady) { return; }
      window.__hnAppReady = true;

      var AD_HOST = /(doubleclick|googlesyndication|googleadservices|adservice\.google|adsystem|adnxs|rubiconproject|pubmatic|openx\.net|smartadserver|criteo|taboola|outbrain|mgid\.|revcontent|zedo|yieldmo|popads|popcash|propellerads|clickadu|exoclick|juicyads|trafficjunky|adsterra|hilltopads|onclck|bidswitch|casalemedia|moatads|sharethrough|teads|adsrvr|applovin|unityads|vungle|ironsrc|chartboost|inmobi|smaato|trafficstars|adspyglass|popunder|adcash|adfox|adriver)/i;

      // 白名单：凡是带这些字样（下载 / 播放 / 按钮）的元素绝对不动
      var SAFE = /(download|dl-|下載|下载|play|播放|btn|button|link|watch)/i;

      // 严格广告标识：只有明确写着广告命名的才隐藏
      var STRICT_AD = /(adsbygoogle|adsense|advertisement|advertisment|contentads|ad-banner|ad_banner|ad-slot|ad_slot|ad-unit|ad_unit|ad-container|ad_container|ad-wrapper|ad_wrapper|ad-box|ad_box|adframe|ad-frame|adsbox|ads-box|advert-box|advertbox|advert-container|popunder|popads|banner-ad|banner_ad|dfp-ad|google-ad|sponsor-ad|taboola|outbrain)/i;

      // 记录"用户刚点的是不是下载/播放类元素"，这类触发的 window.open 放行
      var lastClickSafe = false;
      var safeTimer = null;
      document.addEventListener("click", function (ev) {
        var t = null;
        try { t = ev.target; } catch (e) { return; }
        var desc = "";
        if (t) {
          desc += " " + (t.innerText || t.textContent || "");
          var box = t.closest ? t.closest("a, button, div, li, td") : null;
          if (box) {
            desc += " " + (typeof box.className === "string" ? box.className : "");
            desc += " " + (box.getAttribute("href") || "");
          }
        }
        if (SAFE.test(desc)) {
          lastClickSafe = true;
          if (safeTimer) { clearTimeout(safeTimer); }
          safeTimer = setTimeout(function () { lastClickSafe = false; }, 1500);
        }
      }, true);

      // ---- 1) 弹窗：只放行站内、视频直链、以及用户点了下载/播放后的跳转 ----
      var nativeOpen = window.open;
      window.open = function (url) {
        try {
          var u = new URL(url || "", location.href);
          var sameSite = /hanime/i.test(u.hostname);
          var isMedia = /\.(mp4|webm|mov|m4v|mkv|ts|zip|apk)(\?|$)/i.test(u.pathname + u.search);
          if (!AD_HOST.test(u.hostname) && (sameSite || isMedia || lastClickSafe)) {
            lastClickSafe = false;
            return nativeOpen.apply(window, arguments);
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
          // 白名单优先：下载/播放/按钮类一律跳过
          if (SAFE.test(idc)) { continue; }
          if (SAFE.test((el.innerText || "").slice(0, 60))) { continue; }
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
