// Runs the JS engine to produce (1) phone lookup fixtures for the Java fake and (2) expected scores.
const vm = require("vm"), fs = require("fs"), path = require("path");
const root = path.join(__dirname, "../../..");
const ctx = { Intl }; ctx.globalThis = ctx; ctx.self = ctx; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(root, "vendor/libphonenumber-max.js"), "utf8"), ctx);
const realPh = require(path.join(root, "phone.js")).create(ctx.libphonenumber, require(path.join(root, "phone_data.json")));
const fixtures = { lookup: {}, extract: {} };
const ph = {
  lookup: (raw, o) => { const r = realPh.lookup(raw, o); fixtures.lookup[String(raw) + "|" + ((o && o.claimedOrg) || "none")] = r; return r; },
  extract: (t, h) => { const r = realPh.extract(t, h); fixtures.extract[t] = r; return r; },
};
const sl = require(path.join(root, "engine.js")).create(require(path.join(root, "rules.json")), { phone: ph });
const expected = [];
for (const c of require(path.join(root, "tests/cases.json"))) {
  if (c.kind === "call") continue;
  const r = c.kind === "link" ? sl.analyzeLink(c.input) : sl.analyzeMessage(c.input);
  expected.push({ kind: c.kind, input: c.input, score: r.score, level: r.level.key, ids: r.reasons.map((x) => x.id).sort() });
}
for (const c of require(path.join(root, "tests/sms_cases.json"))) {
  const r = sl.analyzeSms(c.sender, c.body);
  expected.push({ kind: "sms", sender: c.sender, input: c.body, score: r.score, level: r.level.key, ids: r.reasons.map((x) => x.id).sort(), senderKind: r.info.sender.kind });
}
for (const n of ["9845012345", "+92 300 1234567", "1600123456", "1401234567", "+44 7700 900123", "011 2345 6789"]) {
  const r = sl.analyzeNumber(n); const k = sl.callerKind(r.info.numberDetails);
  expected.push({ kind: "number", input: n, score: r.score, level: r.level.key, ids: r.reasons.map((x) => x.id).sort(), caller: k.kind });
}
for (const t of ["https://xn--pple-43d.com", "http://192.168.4.20/hdfc/netbanking", "https://bit.ly/3xYz12", "https://www.hdfcbank.com@evil-site.ru/login", "https://a.b.c.d.example.com/x"]) {
  const r = sl.analyzeAuto(t); expected.push({ kind: "auto", input: t, score: r.score, level: r.level.key, ids: r.reasons.map((x) => x.id).sort() });
}
// Cases from tests/test_new_checks.js (rules 1.1: new message rules, UPI IDs, payment screenshots). The test file is
// run against a recording stub so its cases stay defined in one place, then each call is replayed on the real engine.
const calls = [];
{
  const stub = { create: () => new Proxy({}, { get: (_, method) => (arg) => { calls.push({ method, arg }); return { score: 0, level: { key: "safe" }, reasons: [] }; } }) };
  const src = fs.readFileSync(path.join(root, "tests/test_new_checks.js"), "utf8");
  const req = (m) => (/engine\.js$/.test(m) ? stub : require(path.join(root, "tests", m)));
  new Function("require", "console", "process", src)(req, { log() {} }, { exit() {} });
}
// Extra parity-only edge cases (amount formatting, URI decoding, JS whitespace/word rules, dates, reference numbers).
const NOW = Date.UTC(2026, 9, 13, 12);
for (const arg of [
  "upi://pay?pa=abc.refund%40ybl&pn=Help%20Desk&tn=claim%20cashback&am=1234567.5",
  "upi://pay?pa=x.prize@ybl&tn=%E0%A4&am=250%0A",
  "UPI://PAY?PA=Gov.Fine@SBI&PN=Police%2BDept&am=99.99",
  "upi:pay?pa=919876543210@paytm&pn=RBI%20Refund",
  "someone@constructor",
  "  09876543210@ybl\u00a0",
  "upi://pay?pn=NoPayee",
]) calls.push({ method: "analyzeAuto", arg });
for (const arg of [
  "Pay Rs\u00a0500 processing fee to release your parcel, it is held at customs",
  "Please send money to kyc.verify.help@paytm or upi://pay?pa=reward.claim@ibl&tn=receive%20prize now",
  "आपका ₹५०० refund pending है, OTP बताओ",
  "My new number, transfer to papa.ji@okicici and also pay@sbi",
]) calls.push({ method: "analyzeMessage", arg });
for (const arg of [
  { text: "Payment Successful Rs 2,50,000 13 Oct 2026 UPI Ref No 612312345678 to shop@okaxis", now: NOW, expectedAmount: 1234.5678, myUpi: "Shop@OKAXIS " },
  { text: "Paid ₹ 1,23,456.5 on 12/10/2026 UTR 628512345678 PhonePe", now: NOW, expectedAmount: "0x10" },
  { text: "Paid ₹ 999 on 2026-10-12 txn id ABCD12345678 upi transaction id 628512345678 Paytm", now: NOW, expectedAmount: " " },
  { text: "Transaction successful INR 15,00 at 10:32 PM, 12th October, 2026 reference number 1234 5678 9012", now: NOW, expectedAmount: "-0.0004", imageEditor: "  Adobe Photoshop Express Editor App v2  " },
  { text: "Payment failed. Amount ₹500 will be credited back. Order ID: 9X8Y7Z6W5V Google Pay 31/04/2026", now: NOW, expectedAmount: "abc", myUpi: "not-a-vpa" },
  { text: "Rs. 1,0,00 sent to friend@ybl. Sent by mistake please return the amount. Oct 12, 2026", now: NOW, expectedAmount: "1e3" },
  { text: "", now: NOW },
]) calls.push({ method: "analyzePayment", arg });

const plain = require(path.join(root, "engine.js")).create(require(path.join(root, "rules.json")));
const newChecks = [];
for (const c of calls) {
  const run = (eng) => (c.method === "analyzePayment" ? eng.analyzePayment(c.arg) : c.method === "analyzeAuto" ? eng.analyzeAuto(c.arg) : eng.analyzeMessage(c.arg));
  const r = run(sl), p = run(plain);
  const e = { kind: c.method === "analyzePayment" ? "payment" : c.method === "analyzeAuto" ? "auto" : "message", input: c.arg, score: r.score, level: r.level.key,
    label: r.level.label, ids: r.reasons.map((x) => x.id).sort(), advice: r.advice, reasons: r.reasons.map((x) => [x.id, x.title, x.detail, x.weight]) };
  // Python runs these without the phone layer too, so both must agree.
  if (p.score !== r.score || JSON.stringify(p.advice) !== JSON.stringify(r.advice) || JSON.stringify(p.reasons.map((x) => x.id).sort()) !== JSON.stringify(e.ids)) throw new Error("phone layer changes result for " + JSON.stringify(c.arg));
  expected.push(e);
  newChecks.push(e);
}
fs.writeFileSync(path.join(root, "python/tests/new_checks_expected.json"), JSON.stringify(newChecks, null, 1));
fs.writeFileSync(path.join(__dirname, "phone_fixtures.json"), JSON.stringify(fixtures));
fs.writeFileSync(path.join(__dirname, "expected.json"), JSON.stringify(expected, null, 1));
console.log("fixtures:", Object.keys(fixtures.lookup).length, "lookups,", Object.keys(fixtures.extract).length, "extracts; expected:", expected.length, "(" + newChecks.length + " UPI/payment/new-rule cases, also in python/tests/new_checks_expected.json)");
