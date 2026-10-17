// Second Look — JS API layer used by the iOS app and iOS extensions through JavaScriptCore.
// Loaded after libphonenumber, phone data, phone.js, rules and engine.js. Every function returns a JSON string.
var SL = (function () {
  var g = typeof globalThis !== "undefined" ? globalThis : this;
  var phone = null;
  try { phone = g.SecondLookPhone.create(g.libphonenumber, g.SECONDLOOK_PHONE_DATA, { home: "IN" }); } catch (e) { phone = null; }
  var eng = g.SecondLookEngine.create(g.SECONDLOOK_RULES, { phone: phone, home: "IN" });

  function blockedReasons(number, blockedJson) {
    var list = [];
    try { list = JSON.parse(blockedJson || "[]"); } catch (e) { list = []; }
    var d = phone ? phone.lookup(number, { home: "IN" }) : null;
    var e164 = d && d.e164;
    for (var i = 0; i < list.length; i++) {
      if (list[i].number === e164) {
        return [{ id: "blocked_by_you", title: "You reported this number (" + list[i].label + ")", detail: "You marked this number earlier. Second Look keeps that list only on this phone.", weight: list[i].kind === "safe" ? -20 : 50 }];
      }
    }
    return [];
  }

  return {
    analyzeAuto: function (text) { return JSON.stringify(eng.analyzeAuto(text)); },
    analyzeSms: function (sender, body) { return JSON.stringify(eng.analyzeSms(sender, body)); },
    analyzeNumber: function (number, blockedJson) {
      var r = eng.analyzeNumber(number);
      var extra = blockedReasons(number, blockedJson);
      if (extra.length) r = eng.rescore(r, extra);
      var scam = extra.some(function (x) { return x.weight > 0; });
      r.info.caller = eng.callerKind(r.info.numberDetails, scam);
      return JSON.stringify(r);
    },
    analyzeUpi: function (s) { return JSON.stringify(eng.analyzeUpi(s)); },
    analyzePayment: function (inputJson) {
      var o = {};
      try { o = JSON.parse(inputJson || "{}") || {}; } catch (e) { o = {}; }
      return JSON.stringify(eng.analyzePayment({ text: String(o.text || ""), expectedAmount: o.expectedAmount, myUpi: o.myUpi, imageEditor: o.imageEditor }));
    },
    analyzeDocument: function (inputJson) {
      var o = {};
      try { o = JSON.parse(inputJson || "{}") || {}; } catch (e) { o = {}; }
      return JSON.stringify(eng.analyzeDocument({ text: String(o.text || ""), docType: o.docType, file: o.file || {}, aadhaarQr: o.aadhaarQr || null }));
    },
    lookupNumber: function (number) { return JSON.stringify(eng.lookupNumber(number)); },
    reportTypes: function () { return JSON.stringify(g.SECONDLOOK_RULES.reportTypes); },
  };
})();
