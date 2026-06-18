import Foundation

/// MAIN-world (`.page`) script that hooks YouTube's caption fetch + the
/// `youtubei.googleapis.com/youtubei/v1/player` API response so we can
/// extract captions regardless of which code path the page uses.
///
/// 2026-06-17 revision — adds three fixes for the regression where
/// mobile WKWebView stopped catching captions while the browser plugin
/// (running in a real desktop Chrome context) still worked:
///
///   1. **Broader URL matching.** YouTube migrated mobile-web players
///      from `/api/timedtext?...` to `youtubei.googleapis.com/youtubei/
///      v1/player` (which returns `captionTracks[].baseUrl` inside its
///      JSON body). The old hook only matched `/api/timedtext`. Now we
///      catch both paths PLUS any URL containing the substring
///      "timedtext" as a safety net for whatever YouTube does next.
///
///   2. **Player-response synthetic fetch.** Even when YouTube returns a
///      player response containing valid `captionTracks`, the player
///      itself won't issue the timedtext fetch unless CC is on (and
///      mobile-web defaults CC OFF, "to save data"). We now parse the
///      player response ourselves, pick the best English track
///      (manual > auto > first available), append `fmt=json3` if
///      missing, and call `fetch()` directly. The result flows through
///      the SAME path as a player-issued fetch, so the rest of the
///      Swift pipeline doesn't need to know about this.
///
///   3. **Telemetry to `whatsubDebug` message handler.** Every key
///      event (hook installed, fetch seen, timedtext matched, player
///      response parsed) posts a structured event. Swift accumulates
///      these and dumps them to OSLog on timeout — gives us a forensic
///      trail when extraction silently fails. Zero impact on success
///      path. Failures previously surfaced "未捕获到字幕" with no
///      indication of where in the pipeline it died.
enum CaptionHookJS {
    static let source = #"""
    (function installCaptionsHook() {
      if (window.__whatsubHookInstalled) return;
      window.__whatsubHookInstalled = true;

      function isTimedtext(u){
        if (typeof u !== "string") return false;
        return u.indexOf("/api/timedtext") !== -1
            || u.indexOf("timedtext") !== -1;   // catch-all fallback
      }
      function isPlayerApi(u){
        if (typeof u !== "string") return false;
        return u.indexOf("youtubei/v1/player") !== -1;
      }

      function postCaptions(url, body){
        // 2026-06-18 — Skip if we're not on the target /watch page. Posting
        // captions from the warmup homepage's preview / a navigated-to
        // recommendation video would feed the Swift parser the wrong cues
        // (or trigger a misleading "got body but parser dropped it" log).
        if (!isOnTargetVideo()) {
          postDebug("skip_post_off_target", location.pathname + " v=" + (new URLSearchParams(location.search).get('v') || ''));
          return;
        }
        try { window.webkit.messageHandlers.whatsubCaptions.postMessage({ url: url, body: body }); } catch(e){}
      }
      function postDebug(event, info){
        try { window.webkit.messageHandlers.whatsubDebug.postMessage({ event: event, info: String(info || "") }); } catch(e){}
      }

      postDebug("hook_installed", location.href);

      // 2026-06-18 — Gate caption capture on "we're on the right page".
      // The hook installs on EVERY navigation (warmup homepage, the watch
      // URL we asked for, iframes, AND any video YouTube might navigate
      // us to via recommendation thumbnails accidentally clicked by
      // nudgeAnyCaptionToggle). Without this gate, we'd post captions
      // from random preview videos and get 404s on the wrong timedtext
      // URLs — making BotGuard's real behaviour impossible to diagnose.
      //
      // window.__whatsubTargetVideoId is injected by CaptionExtractor via
      // WKUserScript before this hook runs, so it's always available.
      function isOnTargetVideo() {
        try {
          if (location.pathname !== '/watch') return false;
          var target = window.__whatsubTargetVideoId;
          if (!target) return false;
          var params = new URLSearchParams(location.search);
          return params.get('v') === target;
        } catch(e) { return false; }
      }

      // Mute any <video> as soon as it shows up + keep muting on a 500ms
      // interval. With WebView-now-visible (item 7) the user would
      // otherwise hear YouTube playback audio during the 25s extract
      // window — annoying. We don't care about audio (we want timedtext),
      // and muted autoplay is more permissive in WebKit too.
      function muteAllVideos() {
        try {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) {
            vs[i].muted = true;
            vs[i].volume = 0;
          }
        } catch(e){}
      }
      muteAllVideos();
      setInterval(muteAllVideos, 500);

      // 2026-06-18 — Aggressive measures (B → revised): use a real player-
      // ready signal instead of hardcoded setTimeout. Two failure modes
      // observed in the wild:
      //   • t=4s nudge_cc_no_button fires because YouTube player still
      //     hasn't built the controls DOM (slow connection).
      //   • t=6s nudge_any_candidates n=4 (now they exist) but it's too
      //     late — synth_fetch has already 404'd on the bot-signed URL.
      // Fix: poll for `<video>` OR `.ytp-subtitles-button` every 300ms;
      // fire the nudge chain the moment either appears. Max 15s budget
      // before giving up (still inside our 25s outer timeout).
      //
      // Also: CC click is now GUARDED on aria-pressed !== 'true' so we
      // don't accidentally TURN OFF an already-on CC. The 2026-06-18 log
      // showed `pressed=true` → we click → CC goes off → timedtext stops.
      function nudgeVideoPlay() {
        try {
          var v = document.querySelector('video');
          if (!v) { postDebug("nudge_no_video", ""); return; }
          v.muted = true;
          var p = v.play();
          if (p && p.then) {
            p.then(function() { postDebug("nudge_video_play_ok", ""); })
             .catch(function(e) { postDebug("nudge_video_play_blocked", String(e)); });
          } else {
            postDebug("nudge_video_play_legacy", "");
          }
        } catch(e) { postDebug("nudge_video_play_fail", String(e)); }
      }
      function nudgeCCButton() {
        try {
          var btn = document.querySelector('.ytp-subtitles-button');
          if (!btn) { postDebug("nudge_cc_no_button", ""); return; }
          var pressed = btn.getAttribute('aria-pressed');
          postDebug("nudge_cc_pre_click", "pressed=" + pressed);
          if (pressed === 'true') {
            postDebug("nudge_cc_already_on", "skipping click");
            return;
          }
          btn.click();
          postDebug("nudge_cc_clicked", "");
        } catch(e) { postDebug("nudge_cc_fail", String(e)); }
      }
      function nudgeAnyCaptionToggle() {
        try {
          // 2026-06-18 — SCOPE to the player chrome (.ytp-chrome-controls
          // or .ytp-right-controls) to prevent clicking recommendation
          // thumbnails whose aria-labels also mention "subtitles" — that's
          // what navigated us to `lRz9h75kDqc` instead of staying on the
          // target video in the 2026-06-18 failure log. Without the scope
          // we'd match 11+ candidates per page including links, settings
          // menu items, and recommendation cards.
          var chrome = document.querySelector('.ytp-chrome-controls') || document.querySelector('.ytp-right-controls');
          if (!chrome) {
            postDebug("nudge_any_no_chrome", "player toolbar not yet rendered");
            return;
          }
          var candidates = chrome.querySelectorAll('[aria-label*="ubtitle" i], [aria-label*="字幕"], [data-tooltip-target-id*="ubtitle" i]');
          postDebug("nudge_any_candidates", "n=" + candidates.length);
          var clicked = 0;
          for (var i = 0; i < candidates.length; i++) {
            var el = candidates[i];
            if (el.getAttribute && el.getAttribute('aria-pressed') === 'true') continue;
            // Belt-and-suspenders — refuse to click anything that's an <a>
            // (navigation) or has role="menuitem" (settings panel items).
            var tag = (el.tagName || '').toUpperCase();
            if (tag === 'A') continue;
            if (el.getAttribute && el.getAttribute('role') === 'menuitem') continue;
            try { el.click(); clicked++; } catch(e){}
          }
          postDebug("nudge_any_clicked", "n=" + clicked);
        } catch(e) { postDebug("nudge_any_fail", String(e)); }
      }
      // Player-ready poller. Fires the nudge chain once <video> exists
      // OR the CC button exists (whichever comes first). Falls back to
      // best-effort if neither shows up by maxWait.
      function waitForPlayerReady(cb, maxWait) {
        var start = Date.now();
        function check() {
          if (document.querySelector('video') || document.querySelector('.ytp-subtitles-button')) {
            postDebug("player_ready", "after=" + (Date.now() - start) + "ms");
            cb();
            return;
          }
          if (Date.now() - start > maxWait) {
            postDebug("player_ready_timeout", "after=" + (Date.now() - start) + "ms");
            cb();
            return;
          }
          setTimeout(check, 300);
        }
        check();
      }
      waitForPlayerReady(function() {
        nudgeVideoPlay();
        setTimeout(nudgeCCButton, 800);
        setTimeout(nudgeAnyCaptionToggle, 2000);
      }, 15000);

      function handlePlayerResponse(url, body) {
        try {
          var obj = JSON.parse(body);
          var ct = obj
                && obj.captions
                && obj.captions.playerCaptionsTracklistRenderer
                && obj.captions.playerCaptionsTracklistRenderer.captionTracks;
          if (!ct || !ct.length) {
            postDebug("player_no_captions", "tracks=0");
            return;
          }
          postDebug("player_tracks_found", "n=" + ct.length);
          // Pick: English manual > English auto > first available.
          var pick = null;
          for (var i = 0; i < ct.length; i++) {
            if (ct[i].languageCode === "en" && !ct[i].kind) { pick = ct[i]; break; }
          }
          if (!pick) {
            for (var j = 0; j < ct.length; j++) {
              if (ct[j].languageCode === "en") { pick = ct[j]; break; }
            }
          }
          if (!pick) pick = ct[0];

          var trackUrl = pick.baseUrl;
          if (!trackUrl) {
            postDebug("player_no_baseurl", JSON.stringify(pick).slice(0, 200));
            return;
          }
          if (trackUrl.indexOf("fmt=") === -1) {
            trackUrl += (trackUrl.indexOf("?") === -1 ? "?" : "&") + "fmt=json3";
          }
          postDebug("player_track_picked", (pick.languageCode || "?") + (pick.kind ? "(" + pick.kind + ")" : ""));

          // Synthetic fetch — direct request to the timedtext URL the
          // player would have made if CC were on. Our own fetch hook
          // will re-catch this and post() it via the timedtext path,
          // so we don't double-post here.
          fetch(trackUrl).then(function(r){
            if (!r || !r.ok) { postDebug("synth_fetch_not_ok", String(r && r.status)); return; }
            return r.text();
          }).then(function(t){
            if (t) {
              postDebug("synth_fetch_body", "len=" + t.length);
              // 2026-06-18 — Detect a BotGuard login-wall response and signal
              // Swift to abort early. When YT rejects our timedtext URL it
              // often serves a 200 OK with the full sign-in page HTML
              // (~2MB) — that's never parseable as json3, and waiting out
              // the 25s timeout serves no purpose.
              //
              // Two converging signals (need either):
              //   1. HTML markers in the first 400 chars: <!doctype, <html,
              //      <head>, accounts.google, signin, "youtube.com/signin"
              //   2. Body > 50KB AND doesn't look like JSON / XML / WebVTT.
              //      Real json3 captions are usually < 30KB even for hour-
              //      long videos (it's just text); anything 50KB+ that
              //      parsed to "not JSON" is almost certainly an HTML page.
              var trimmed = t.trim();
              var head = trimmed.slice(0, 400).toLowerCase();
              var looksLikeJson = head.charAt(0) === '{';
              var looksLikeXml = head.indexOf('<?xml') === 0
                              || head.indexOf('<transcript') === 0
                              || head.indexOf('<tt ') === 0;
              var looksLikeVtt = head.indexOf('webvtt') === 0;
              var hasHtmlMarker = head.indexOf('<!doctype') === 0
                              || head.indexOf('<html') === 0
                              || head.indexOf('<head>') !== -1
                              || head.indexOf('accounts.google') !== -1
                              || head.indexOf('signin') !== -1
                              || head.indexOf('"signinredirecturl"') !== -1;
              var isHuge = t.length > 50000;
              var likelyWall = hasHtmlMarker
                            || (isHuge && !looksLikeJson && !looksLikeXml && !looksLikeVtt);
              if (likelyWall) {
                postDebug("login_wall_detected", "len=" + t.length + " head=" + head.slice(0, 80).replace(/\s+/g, ' '));
              } else {
                postCaptions(trackUrl, t);
              }
            }
          }).catch(function(e){ postDebug("synth_fetch_fail", String(e)); });
        } catch(e) {
          postDebug("player_parse_fail", String(e));
        }
      }

      var origFetch = window.fetch;
      window.fetch = function(input, init){
        var url = typeof input === "string" ? input
              : (input && input.url) ? input.url : String(input);
        var p = origFetch.apply(this, arguments);
        try {
          if (isTimedtext(url)) {
            postDebug("timedtext_fetch_seen", url.slice(0, 120));
            p.then(function(res){
              if (!res || !res.ok) { postDebug("timedtext_not_ok", String(res && res.status)); return; }
              res.clone().text().then(function(t){
                if (t) { postDebug("timedtext_body", "len=" + t.length); postCaptions(url, t); }
              }).catch(function(e){ postDebug("timedtext_text_fail", String(e)); });
            }).catch(function(e){ postDebug("timedtext_promise_fail", String(e)); });
          } else if (isPlayerApi(url)) {
            postDebug("player_fetch_seen", url.slice(0, 120));
            p.then(function(res){
              if (!res || !res.ok) { postDebug("player_not_ok", String(res && res.status)); return; }
              res.clone().text().then(function(t){ handlePlayerResponse(url, t); });
            }).catch(function(e){ postDebug("player_promise_fail", String(e)); });
          }
        } catch(e){ postDebug("fetch_outer_fail", String(e)); }
        return p;
      };

      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, url){
        try { this.__wsUrl = String(url); } catch(e){}
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(){
        var url = this.__wsUrl, xhr = this;
        if (url && isTimedtext(url)) {
          postDebug("timedtext_xhr_seen", url.slice(0, 120));
          this.addEventListener("load", function(){
            try {
              if (xhr.status === 200 && xhr.responseText) {
                postDebug("timedtext_xhr_body", "len=" + xhr.responseText.length);
                postCaptions(url, xhr.responseText);
              }
            } catch(e){ postDebug("timedtext_xhr_fail", String(e)); }
          });
        } else if (url && isPlayerApi(url)) {
          postDebug("player_xhr_seen", url.slice(0, 120));
          this.addEventListener("load", function(){
            try {
              if (xhr.status === 200 && xhr.responseText) {
                handlePlayerResponse(url, xhr.responseText);
              }
            } catch(e){ postDebug("player_xhr_fail", String(e)); }
          });
        }
        return origSend.apply(this, arguments);
      };
    })();
    """#
}
