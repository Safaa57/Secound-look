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

// Cases from tests/test_documents.js (rules 1.2: IDs, passports, statements, letters, file signs), collected the same way.
const docCalls = [];
{
  const stub = { create: () => new Proxy({}, { get: (_, method) => (arg) => { docCalls.push({ method, arg }); return { score: 0, level: { key: "safe" }, reasons: [] }; } }) };
  const src = fs.readFileSync(path.join(root, "tests/test_documents.js"), "utf8");
  const req = (m) => (/engine\.js$/.test(m) ? stub : require(path.join(root, "tests", m)));
  new Function("require", "console", "process", src)(req, { log() {} }, { exit() {} });
}
// Extra parity-only document edge cases.
{
  const DNOW = Date.UTC(2026, 9, 17, 12);
  const mrzCheck = (s) => String([...s].reduce((a, ch, i) => a + (ch === "<" ? 0 : /\d/.test(ch) ? +ch : ch.charCodeAt(0) - 55) * [7, 3, 1][i % 3], 0) % 10);
  const td3 = (num, nat, dob, sex, exp, opt) => {
    const n = (num + "<<<<<<<<<").slice(0, 9), o = (opt + "<<<<<<<<<<<<<<").slice(0, 14);
    const oc = /^<+$/.test(o) ? "<" : mrzCheck(o);
    const b = n + mrzCheck(n) + nat + dob + mrzCheck(dob) + sex + exp + mrzCheck(exp) + o + oc;
    return b + mrzCheck(b.slice(0, 10) + b.slice(13, 20) + b.slice(21, 43));
  };
  const L1 = "P<INDSHARMA<<RAHUL<KUMAR<<<<<<<<<<<<<<<<<<<<";
  const spaced = (l) => l.replace(/(.{5})/g, "$1 ").replace(/<</g, "\u2039<");
  const A = td3("Z1234567", "IND", "990101", "M", "310101", "AB12345C");
  const B = td3("K7654321", "IND", "<<<<<<", "F", "250101", "");
  const docs = [
    { text: "REPUBLIC OF INDIA\nPassport No. Z1234567\n" + spaced(L1).toLowerCase() + "\n" + spaced(A).replace(/</, "\u3008") + "\u00ab\t" },
    { text: "Passport\n" + L1 + "\r\n" + B + "\r\n" },
    { text: L1 + "\n" + A.slice(0, 43) + "9" },
    { text: "Passport\n" + L1.replace("P<", "P\u00ab") + "\n" + A, docType: "letter" },
    { text: "ACCOUNT STATEMENT\n01-10-2026 Opening 10,000.00 Cr\n02-10-2026 UPI/shop 500.00 Dr 9,500.00 Cr\n03-10-2026 NEFT salary 25,000.00 Cr 34,500.00 Cr\n04-10-2026 ATM 2,000.00 Dr 32,500.00 Cr\n05-10-2026 Interest 0.00 32,500.00 Cr\n06-10-2026 Charges 1,000.00\n07-10-2026 IMPS 1,500.00 Dr 31,000.00 Cr" },
    { text: "Bank Statement\r\n05 Oct 2026 POS 100.00 900.00\r\n01 Oct 2026 POS 100.00 700.00\r\n20 Sep 2026 POS 100.00 650.00\r\n21 Sep 2026 POS 50.00 600.00\r\nOpening balance: Rs. 1,000.00\r\nTotal debits 400.00\r\nTotal credits 0.00\r\nClosing balance 600.00", file: { kind: "pdf", producer: "Microsoft Word - iLovePDF", creator: "Microsoft Word", created: "2026-10-01", modified: "2026-10-01T00:11:00+00:00", revisions: "2" } },
    { text: "Statement of Account\n1/10/26\ud83d\ude00 grocery 500.00 9,500.00\n2/10/26\ud83d\ude00 salary 1,000.00 10,500.00\n3/10/26 rent 4,000.00 6,500.00", file: { kind: "pdf", producer: "iText", creator: "iText", created: "2026-02-31T00:00:00Z", modified: "D:20261012", revisions: 2.5 } },
    { text: "Opening Balance 100.00\n12/10/2026 x 50.00 150.00", docType: "statement", file: { created: "2026-09-01 10:00:00Z", modified: "2026-09-01T10:05:00Z", imageEditor: " " } },
    { text: "Remit to IFSC: sbin0001234 or ifs code hdfc1234567, IFSC-ICIC0ABCDEF" },
    { text: "Tax Invoice\nGSTIN 27ABCDE1234F1Z5\nPAN ABCDE1234F, ABCPE1234F, abcpe1234f\nGSTIN: 99AAPFU0939F1ZV 40AAPFU0939F1ZV" },
    { text: "\u092d\u093e\u0930\u0924 \u0938\u0930\u0915\u093e\u0930\n\u0906\u0927\u093e\u0930\n\u0930\u093e\u0939\u0941\u0932 \u0936\u0930\u094d\u092e\u093e\n\u091c\u0928\u094d\u092e \u0924\u093f\u0925\u093f: \u0967\u0968/\u0966\u096b/\u0967\u096f\u096f\u0966\n4991 1866 5245\n\u096a\u096f\u096f\u0967 \u0967\u096e\u096c\u096c \u096b\u0968\u096a\u096c" },
    { text: "UIDAI 4991 1866 5246 4991-1866-5246 2345 6789 0123 3456 7890 1234 5678 9012 3456 6789 0123 4567", docType: "auto" },
    { text: "Rahul Sharma\nDOB 12.05.1990\n4991 1866 5246\nAadhaar", aadhaarQr: { decoded: true, signatureChecked: false, name: "R.  Sharma", dob: "DOB 13-05-1990", gender: "M", last4: 5246 } },
    { text: "Government of India Priya Verma 4991 1866 5246", aadhaarQr: { decoded: true, signatureChecked: true, signatureValid: "yes", name: "Al", last4: "1234", dob: 12051990 } },
    { text: "Aadhaar", aadhaarQr: { decoded: false, oldXml: true } },
    { text: "Office of the Commissioner of Police\nNotice u/s 41A\n\nYou must deposit Rs 50,000 for verification of your account.\nReply to: complaint.cell.mumbai@gmail.com", file: { kind: "image", imageEditor: "Snapseed" } },
    { text: "", docType: "id" },
    {},
  ];
  for (const d of docs) docCalls.push({ method: "analyzeDocument", arg: Object.assign({ now: DNOW }, d) });
  for (const a of ["", "0", "12a4", "499118665246", "4991 1866 5246", "27aapfu0939f1zv", "27AAPFU0939F1Z", "27AAPFU0939F1ZVX", "\u0967\u0968"]) {
    docCalls.push({ method: "verhoeffOk", arg: a });
    docCalls.push({ method: "gstinOk", arg: a });
  }
}
const pick = (info) => { const o = {}; for (const k of ["docType", "ids", "statement", "file", "passport", "qr"]) if (k in info) o[k] = info[k]; return o; };
const documents = [];
for (const c of docCalls) {
  let e;
  if (c.method === "verhoeffOk" || c.method === "gstinOk") {
    e = { kind: "helper", method: c.method, input: c.arg, result: sl[c.method](c.arg) };
  } else {
    const r = sl.analyzeDocument(c.arg), p = plain.analyzeDocument(c.arg);
    if (JSON.stringify([p.score, p.advice, p.reasons.map((x) => x.id)]) !== JSON.stringify([r.score, r.advice, r.reasons.map((x) => x.id)])) throw new Error("phone layer changes result for " + JSON.stringify(c.arg));
    e = { kind: "document", input: c.arg, score: r.score, level: r.level.key, label: r.level.label, ids: r.reasons.map((x) => x.id).sort(), advice: r.advice,
      reasons: r.reasons.map((x) => [x.id, x.title, x.detail, x.weight]), info: pick(r.info), echo: r.input };
  }
  expected.push(e);
  documents.push(e);
}
fs.writeFileSync(path.join(root, "python/tests/documents_expected.json"), JSON.stringify(documents, null, 1));
fs.writeFileSync(path.join(__dirname, "phone_fixtures.json"), JSON.stringify(fixtures));
fs.writeFileSync(path.join(__dirname, "expected.json"), JSON.stringify(expected, null, 1));
console.log("fixtures:", Object.keys(fixtures.lookup).length, "lookups,", Object.keys(fixtures.extract).length, "extracts; expected:", expected.length, "(" + newChecks.length + " UPI/payment/new-rule cases, also in python/tests/new_checks_expected.json; " + documents.length + " document cases, also in python/tests/documents_expected.json)");
