import Foundation

/// MAIN-world (`.page`) script: hooks window.fetch + XMLHttpRequest so that when
/// the YouTube player fetches /api/timedtext (its own po_token-signed request),
/// we capture the body and hand it to Swift via the `whatsubCaptions` message
/// handler. Adapted from the whatsub-plugin web-plugin/public/fetchHook.js
/// (post() retargeted to webkit.messageHandlers). Must be injected at
/// documentStart so it installs before the player's first timedtext request.
enum CaptionHookJS {
    static let source = #"""
    (function installCaptionsHook() {
      if (window.__whatsubHookInstalled) return;
      window.__whatsubHookInstalled = true;
      function isTimedtext(u){ return typeof u === "string" && u.indexOf("/api/timedtext") !== -1; }
      function post(url, body){
        try { window.webkit.messageHandlers.whatsubCaptions.postMessage({ url: url, body: body }); } catch(e){}
      }
      var origFetch = window.fetch;
      window.fetch = function(input, init){
        var p = origFetch.apply(this, arguments);
        try {
          var url = typeof input === "string" ? input : (input && input.url) ? input.url : String(input);
          if (isTimedtext(url)) {
            p.then(function(res){
              if (!res || !res.ok) return;
              res.clone().text().then(function(t){ if (t) post(url, t); }).catch(function(){});
            }).catch(function(){});
          }
        } catch(e){}
        return p;
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, url){ try { this.__wsUrl = String(url); } catch(e){} return origOpen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var url = this.__wsUrl, xhr = this;
        if (url && isTimedtext(url)) {
          this.addEventListener("load", function(){ try { if (xhr.status===200 && xhr.responseText) post(url, xhr.responseText); } catch(e){} });
        }
        return origSend.apply(this, arguments);
      };
    })();
    """#
}
