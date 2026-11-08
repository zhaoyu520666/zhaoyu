import Foundation
import WebKit

// MARK: - 广告拦截
/// 两层拦截：
/// 1. 原生层：取消一切非用户主动触发的站外跳转、屏蔽广告域名、禁掉 target=_blank 弹窗
/// 2. 网页层：注入脚本隐藏广告元素、屏蔽 window.open 弹窗、干掉"透明全屏广告层"（误触元凶）
enum AdBlocker {

    /// 广告 / 弹窗联盟域名关键词
    static let blockedHostKeywords: [String] = [
        "doubleclick", "googlesyndication", "googleadservices", "adservice.google",
        "adsystem", "adnxs", "rubiconproject", "pubmatic", "openx.net", "smartadserver",
        "criteo", "taboola", "outbrain", "mgid.", "revcontent", "zedo", "yieldmo",
        "popads", "popcash", "propellerads", "propellerpops", "clickadu", "exoclick",
        "juicyads", "trafficjunky", "adsterra", "hilltopads", "onclck", "bidswitch",
        "casalemedia", "moatads", "sharethrough", "teads", "adsrvr", "applovin",
        "unityads", "vungle", "ironsrc", "chartboost", "inmobi", "smaato", "adcolony",
        "tapjoy", "mopub", "adtrue", "adnium", "tsyndicate", "trafficstars",
        "adspyglass", "popunder", "adsterra", "clickaine", "adcash", "betweendigital",
        "adfox", "adriver", "gads", "adcolony", "start.io"
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

    /// 注入到网页的脚本：隐藏广告、拦截弹窗、隐藏网页自带的底部导航（由 App 原生底栏代替）
    static let bootstrapJS: String = ##"""
    (function () {
      if (window.__hnAppReady) { return; }
      window.__hnAppReady = true;

      var AD_HOST = /(doubleclick|googlesyndication|googleadservices|adservice\.google|adsystem|adnxs|rubiconproject|pubmatic|openx\.net|smartadserver|criteo|taboola|outbrain|mgid\.|revcontent|zedo|yieldmo|popads|popcash|propellerads|clickadu|exoclick|juicyads|trafficjunky|adsterra|hilltopads|onclck|bidswitch|casalemedia|moatads|sharethrough|teads|adsrvr|applovin|unityads|vungle|ironsrc|chartboost|inmobi|smaato|trafficstars|adspyglass|popunder|adcash|adfox|adriver)/i;

      // ---- 1) 屏蔽新窗口弹窗（广告强制跳转的主要手段）----
      var nativeOpen = window.open;
      window.open = function (url) {
        try {
          var u = new URL(url || "", location.href);
          if (/hanime/i.test(u.hostname) && !AD_HOST.test(u.hostname)) {
            return nativeOpen.apply(window, arguments);
          }
        } catch (e) { /* URL 非法或为空：直接拦掉 */ }
        return null;
      };

      // ---- 2) 隐藏广告元素 ----
      var AD_TOKEN = /(^|[\s_\-])(ads?|adv|advert|adslot|adsense|adunit|adbox|adframe|adsbygoogle|banner|popunder|sponsor)([\s_\-]|$)/i;

      function hide(el) {
        if (!el || el.__hnHidden) { return; }
        el.__hnHidden = 1;
        el.style.setProperty("display", "none", "important");
      }

      function sweepAds(root) {
        if (!root || !root.querySelectorAll) { return; }
        var nodes = root.querySelectorAll("iframe, ins, div, a, img, section, aside");
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (el.__hnHidden) { continue; }
          var idc = ((el.id || "") + " " + (typeof el.className === "string" ? el.className : "")).trim();
          if (idc && AD_TOKEN.test(idc)) { hide(el); continue; }
          if (el.tagName === "IFRAME" && AD_HOST.test(el.src || "")) { hide(el); }
        }
      }

      // ---- 3) 干掉"透明全屏广告层"：盖在下载按钮上、点了就跳出站外 ----
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
          if (cs.position !== "fixed" && cs.position !== "absolute") { continue; }
          var r = a.getBoundingClientRect();
          if (r.width * r.height < vw * vh * 0.3) { continue; }
          var blank = !(a.innerText || "").trim();
          var transparent = (parseFloat(cs.opacity) || 1) < 0.3;
          if (blank || transparent) { hide(a); }
        }
      }

      // ---- 4) 导航项定位（App 原生底栏调用，用网站自己的跳转地址）----
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

      // ---- 5) 隐藏网页自带底部导航（换成 App 原生底栏，避免双栏）----
      function hideSiteNav() {
        var el = findNav("本日排行");
        if (!el) { return; }
        var cur = el, guard = 0;
        while (cur && cur !== document.body && guard++ < 8) {
          var cs = window.getComputedStyle(cur);
          if (cs.position === "fixed" || cs.position === "sticky") {
            var r = cur.getBoundingClientRect();
            if (r.height > 0 && r.height < 160) {
              cur.style.setProperty("display", "none", "important");
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
        setTimeout(function () { pending = false; run(); }, 350);
      }

      run();
      try {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      setTimeout(run, 700);
      setTimeout(run, 1800);
      setTimeout(run, 3500);
      setTimeout(run, 6000);
    })();
    """##
}
