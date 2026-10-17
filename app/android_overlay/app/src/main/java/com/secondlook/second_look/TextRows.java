package com.secondlook.second_look;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Rebuilds OCR text in reading rows. Plain OCR output often comes out column by column, which breaks tables such as
 * bank statements (date, description, debit, credit and balance end up on different lines). Here every recognised
 * line keeps its box; lines whose vertical centres are close (within 0.6 × the median line height) form one row,
 * each row is ordered left to right and joined with two spaces, and rows are joined with "\n".
 * Pure Java (no Android types) so it can be unit tested on a plain JVM.
 */
final class TextRows {
    static final float ROW_FACTOR = 0.6f;
    static final String CELL_GAP = "  ";

    private TextRows() { }

    /** One recognised line and its box in image pixels (top-left origin). */
    static final class Line {
        final String text;
        final float left, top, right, bottom;
        final boolean hasBox;

        Line(String text, float left, float top, float right, float bottom) {
            this.text = text == null ? "" : text.trim();
            this.left = left;
            this.top = Math.min(top, bottom);
            this.right = right;
            this.bottom = Math.max(top, bottom);
            this.hasBox = !(Float.isNaN(left) || Float.isNaN(top) || Float.isNaN(right) || Float.isNaN(bottom));
        }

        /** A line whose position is unknown: kept, but placed after the rebuilt rows. */
        Line(String text) { this(text, Float.NaN, Float.NaN, Float.NaN, Float.NaN); }

        float centreY() { return (top + bottom) / 2f; }

        float height() { return bottom - top; }
    }

    static String build(List<Line> lines) {
        if (lines == null || lines.isEmpty()) return "";
        List<Line> boxed = new ArrayList<>();
        List<Line> loose = new ArrayList<>();
        for (Line l : lines) {
            if (l == null || l.text.isEmpty()) continue;
            if (l.hasBox) boxed.add(l); else loose.add(l);
        }

        StringBuilder out = new StringBuilder();
        if (!boxed.isEmpty()) {
            List<Float> heights = new ArrayList<>();
            for (Line l : boxed) heights.add(Math.max(0f, l.height()));
            Collections.sort(heights);
            float median = heights.get(heights.size() / 2);
            if (median <= 0f) median = 1f;
            float threshold = ROW_FACTOR * median;

            boxed.sort((a, b) -> Float.compare(a.centreY(), b.centreY()));
            List<List<Line>> rows = new ArrayList<>();
            List<Line> row = null;
            float rowCentre = 0f;
            for (Line l : boxed) {
                float cy = l.centreY();
                if (row != null && Math.abs(cy - rowCentre) <= threshold) {
                    row.add(l);
                    rowCentre += (cy - rowCentre) / row.size(); // running mean of the row's centres
                } else {
                    row = new ArrayList<>();
                    row.add(l);
                    rowCentre = cy;
                    rows.add(row);
                }
            }
            for (List<Line> r : rows) {
                r.sort((a, b) -> a.left != b.left ? Float.compare(a.left, b.left) : a.text.compareTo(b.text));
                if (out.length() > 0) out.append('\n');
                for (int i = 0; i < r.size(); i++) {
                    if (i > 0) out.append(CELL_GAP);
                    out.append(r.get(i).text);
                }
            }
        }
        for (Line l : loose) {
            if (out.length() > 0) out.append('\n');
            out.append(l.text);
        }
        return out.toString();
    }

    // ------------------------------------------------------------------ text-geometry check ("layout")
    /** One OCR word and the top / bottom of its box in image pixels. */
    static final class Word {
        final String text;
        final float top, bottom;

        Word(String text, float top, float bottom) {
            this.text = text == null ? "" : text.trim();
            this.top = Math.min(top, bottom);
            this.bottom = Math.max(top, bottom);
        }

        float height() { return bottom - top; }
    }

    /**
     * Looks for words that don't sit like their neighbours, typical of digits or names pasted into a document:
     * in lines with at least 3 words, a word (2+ characters, with a letter or digit) whose box height differs by more
     * than 30% from the line's median word height, or whose bottom edge is off the line's median bottom by more than
     * 35% of the median height. Accumulates over lines (and pages).
     */
    static final class LayoutCheck {
        static final float HEIGHT_DIFF = 0.30f;
        static final float BASELINE_DIFF = 0.35f;
        static final int MAX_SAMPLES = 5;

        boolean checked;
        int lines;
        int odd;
        final List<String> samples = new ArrayList<>();

        void addLine(List<Word> words) {
            checked = true;
            if (words == null || words.size() < 3) return;
            List<Float> heights = new ArrayList<>();
            List<Float> bottoms = new ArrayList<>();
            for (Word w : words) {
                if (w == null || w.text.isEmpty() || Float.isNaN(w.top) || Float.isNaN(w.bottom)) continue;
                heights.add(w.height());
                bottoms.add(w.bottom);
            }
            if (heights.size() < 3) return;
            Collections.sort(heights);
            Collections.sort(bottoms);
            float medH = heights.get(heights.size() / 2);
            float medB = bottoms.get(bottoms.size() / 2);
            if (medH <= 0f) return;
            lines++;
            for (Word w : words) {
                if (w == null || w.text.length() < 2 || !hasLetterOrDigit(w.text)) continue;
                if (Float.isNaN(w.top) || Float.isNaN(w.bottom)) continue;
                boolean badHeight = Math.abs(w.height() - medH) / medH > HEIGHT_DIFF;
                boolean badBase = Math.abs(w.bottom - medB) > BASELINE_DIFF * medH;
                if (badHeight || badBase) {
                    odd++;
                    if (samples.size() < MAX_SAMPLES) samples.add(maskLongDigits(w.text));
                }
            }
        }

        /** {checked, lines, odd, samples} for the engine's file.layout input. */
        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("checked", checked);
            m.put("lines", lines);
            m.put("odd", odd);
            m.put("samples", new ArrayList<Object>(samples));
            return m;
        }

        static Map<String, Object> notChecked() { return new LayoutCheck().toMap(); }
    }

    private static boolean hasLetterOrDigit(String s) {
        for (int i = 0; i < s.length(); i++) if (Character.isLetterOrDigit(s.charAt(i))) return true;
        return false;
    }

    private static final Pattern LONG_DIGITS = Pattern.compile("\\d{8,}");

    /** In any run of 8+ digits, every digit except the last 4 becomes X (account and ID numbers stay hidden). */
    static String maskLongDigits(String s) {
        if (s == null) return "";
        Matcher m = LONG_DIGITS.matcher(s);
        StringBuffer out = new StringBuffer();
        while (m.find()) {
            String run = m.group();
            StringBuilder r = new StringBuilder();
            for (int i = 0; i < run.length() - 4; i++) r.append('X');
            r.append(run.substring(run.length() - 4));
            m.appendReplacement(out, r.toString());
        }
        m.appendTail(out);
        return out.toString();
    }
}
