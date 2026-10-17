package com.secondlook.second_look;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

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
}
