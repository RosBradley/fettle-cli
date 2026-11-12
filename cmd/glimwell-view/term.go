package main

import (
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/charmbracelet/x/ansi"
)

// A command run in the pane writes to a terminal of its own: text, colors,
// spinner frames that overwrite one line, cursor moves, cleared screens and
// the alternate screen pick lists draw on. This small terminal applies all
// of that, so the pane can show the screen as the command drew it, and the
// results can list what it left behind plus the lines that scrolled off the
// top, instead of every intermediate frame.

// maxLines bounds the replayed history; the oldest lines go first.
const maxLines = 50000

type cell struct {
	text  string // one grapheme; "" for the right half of a wide character
	style string // SGR parameters in effect, "" for the default style
}

type buffer struct {
	lines      [][]cell
	top        int // index in lines of the screen's first row
	row, col   int // cursor, relative to the screen
	wrapNext   bool
	savedRow   int
	savedCol   int
	savedStyle sgr
}

type terminal struct {
	width, height int
	main          buffer
	alt           *buffer
	style         sgr
	cursorHidden  bool
}

func newTerminal(width, height int) *terminal {
	if width < 1 {
		width = 80
	}
	if height < 1 {
		height = 24
	}
	return &terminal{width: width, height: height}
}

func (t *terminal) buf() *buffer {
	if t.alt != nil {
		return t.alt
	}
	return &t.main
}

// ensureRow makes the screen row exist in the buffer.
func (t *terminal) ensureRow(b *buffer, row int) {
	for b.top+row >= len(b.lines) {
		b.lines = append(b.lines, nil)
	}
}

func (t *terminal) line(b *buffer, row int) []cell {
	t.ensureRow(b, row)
	return b.lines[b.top+row]
}

func (t *terminal) setLine(b *buffer, row int, l []cell) {
	t.ensureRow(b, row)
	b.lines[b.top+row] = l
}

func (t *terminal) lineFeed() {
	b := t.buf()
	b.wrapNext = false
	if b.row < t.height-1 {
		b.row++
		t.ensureRow(b, b.row)
		return
	}
	// Scroll: the top row joins the history above the screen. The alternate
	// screen keeps no history.
	if b == t.alt {
		b.lines = append(b.lines[1:min(len(b.lines), t.height)], nil)
		return
	}
	b.top++
	t.ensureRow(b, b.row)
	if extra := len(b.lines) - maxLines; extra > 0 {
		b.lines = b.lines[extra:]
		b.top -= extra
	}
}

func (t *terminal) put(text string, width int) {
	b := t.buf()
	if width == 0 {
		// A combining mark joins the character before it.
		l := t.line(b, b.row)
		if c := b.col - 1; c >= 0 && c < len(l) {
			l[c].text += text
		}
		return
	}
	if b.wrapNext || b.col+width > t.width {
		b.col = 0
		t.lineFeed()
	}
	l := t.line(b, b.row)
	for len(l) < b.col+width {
		l = append(l, cell{text: " "})
	}
	l[b.col] = cell{text: text, style: t.style.code()}
	if width == 2 {
		l[b.col+1] = cell{style: t.style.code()}
	}
	t.setLine(b, b.row, l)
	b.col += width
	if b.col >= t.width {
		b.col = t.width - 1
		b.wrapNext = true
	}
}

func (t *terminal) clamp() {
	b := t.buf()
	b.row = max(0, min(b.row, t.height-1))
	b.col = max(0, min(b.col, t.width-1))
	b.wrapNext = false
	t.ensureRow(b, b.row)
}

// eraseCells blanks columns [from, to) of a screen row.
func (t *terminal) eraseCells(row, from, to int) {
	b := t.buf()
	l := t.line(b, row)
	to = min(to, len(l))
	for c := max(0, from); c < to; c++ {
		l[c] = cell{text: " "}
	}
	t.setLine(b, row, l)
}

func (t *terminal) eraseRows(from, to int) {
	b := t.buf()
	for r := max(0, from); r < min(to, t.height); r++ {
		t.ensureRow(b, r)
		b.lines[b.top+r] = nil
	}
}

func (t *terminal) eraseLine(mode int) {
	b := t.buf()
	switch mode {
	case 0:
		t.eraseCells(b.row, b.col, t.width)
	case 1:
		t.eraseCells(b.row, 0, b.col+1)
	default:
		t.eraseRows(b.row, b.row+1)
	}
}

func (t *terminal) eraseDisplay(mode int) {
	b := t.buf()
	switch mode {
	case 0:
		t.eraseCells(b.row, b.col, t.width)
		t.eraseRows(b.row+1, t.height)
	case 1:
		t.eraseRows(0, b.row)
		t.eraseCells(b.row, 0, b.col+1)
	case 2:
		t.eraseRows(0, t.height)
	case 3:
		// Clear the history too, as the menu's clear does.
		t.eraseRows(0, t.height)
		b.lines = b.lines[b.top:]
		b.top = 0
	}
}

// insertLines and deleteLines shift the rows from the cursor to the bottom.
func (t *terminal) insertLines(n int) {
	b := t.buf()
	t.ensureRow(b, t.height-1)
	for ; n > 0; n-- {
		copy(b.lines[b.top+b.row+1:b.top+t.height], b.lines[b.top+b.row:b.top+t.height-1])
		b.lines[b.top+b.row] = nil
	}
}

func (t *terminal) deleteLines(n int) {
	b := t.buf()
	t.ensureRow(b, t.height-1)
	for ; n > 0; n-- {
		copy(b.lines[b.top+b.row:b.top+t.height-1], b.lines[b.top+b.row+1:b.top+t.height])
		b.lines[b.top+t.height-1] = nil
	}
}

func (t *terminal) deleteChars(n int) {
	b := t.buf()
	l := t.line(b, b.row)
	if b.col >= len(l) {
		return
	}
	end := min(len(l), b.col+n)
	l = append(l[:b.col], l[end:]...)
	t.setLine(b, b.row, l)
}

func (t *terminal) insertChars(n int) {
	b := t.buf()
	l := t.line(b, b.row)
	if b.col >= len(l) {
		return
	}
	blanks := make([]cell, n)
	for i := range blanks {
		blanks[i] = cell{text: " "}
	}
	l = append(l[:b.col], append(blanks, l[b.col:]...)...)
	if len(l) > t.width {
		l = l[:t.width]
	}
	t.setLine(b, b.row, l)
}

func (t *terminal) setAlt(on bool) {
	if on && t.alt == nil {
		t.alt = &buffer{}
		t.ensureRow(t.alt, 0)
	} else if !on {
		t.alt = nil
	}
}

func (t *terminal) saveCursor() {
	b := t.buf()
	b.savedRow, b.savedCol, b.savedStyle = b.row, b.col, t.style
}

func (t *terminal) restoreCursor() {
	b := t.buf()
	b.row, b.col, t.style = b.savedRow, b.savedCol, b.savedStyle
	t.clamp()
}

// params parses CSI parameters; missing ones are -1.
func params(s string) []int {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	out := make([]int, len(parts))
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			n = -1
		}
		out[i] = n
	}
	return out
}

// arg returns parameter i, or def when it is missing or zero.
func arg(p []int, i, def int) int {
	if i < len(p) && p[i] > 0 {
		return p[i]
	}
	return def
}

func (t *terminal) csi(private byte, raw string, final byte) {
	p := params(raw)
	b := t.buf()
	if private == '?' {
		if final != 'h' && final != 'l' {
			return
		}
		for _, mode := range p {
			switch mode {
			case 25:
				t.cursorHidden = final == 'l'
			case 47, 1047, 1049:
				if mode == 1049 && final == 'h' {
					t.saveCursor()
				}
				t.setAlt(final == 'h')
				if mode == 1049 && final == 'l' {
					t.restoreCursor()
				}
			}
		}
		return
	}
	if private != 0 {
		return
	}
	switch final {
	case 'A':
		b.row -= arg(p, 0, 1)
	case 'B', 'e':
		b.row += arg(p, 0, 1)
	case 'C', 'a':
		b.col += arg(p, 0, 1)
	case 'D':
		b.col -= arg(p, 0, 1)
	case 'E':
		b.row += arg(p, 0, 1)
		b.col = 0
	case 'F':
		b.row -= arg(p, 0, 1)
		b.col = 0
	case 'G', '`':
		b.col = arg(p, 0, 1) - 1
	case 'd':
		b.row = arg(p, 0, 1) - 1
	case 'H', 'f':
		b.row = arg(p, 0, 1) - 1
		b.col = arg(p, 1, 1) - 1
	case 'J':
		t.eraseDisplay(max(0, arg(p, 0, 0)))
		return
	case 'K':
		t.eraseLine(max(0, arg(p, 0, 0)))
		return
	case 'L':
		t.insertLines(arg(p, 0, 1))
		return
	case 'M':
		t.deleteLines(arg(p, 0, 1))
		return
	case 'P':
		t.deleteChars(arg(p, 0, 1))
		return
	case '@':
		t.insertChars(arg(p, 0, 1))
		return
	case 'X':
		t.eraseCells(b.row, b.col, b.col+arg(p, 0, 1))
		return
	case 'S':
		row := b.row
		b.row = t.height - 1
		for n := arg(p, 0, 1); n > 0; n-- {
			t.lineFeed()
		}
		b.row = row
		return
	case 'T':
		row := b.row
		b.row = 0
		t.insertLines(arg(p, 0, 1))
		b.row = row
		return
	case 's':
		t.saveCursor()
		return
	case 'u':
		t.restoreCursor()
		return
	case 'm':
		t.style.apply(p)
		return
	default:
		return
	}
	t.clamp()
}

// write replays recorded output.
func (t *terminal) write(data []byte) {
	for i := 0; i < len(data); {
		c := data[i]
		switch {
		case c == 0x1b:
			i = t.escape(data, i+1)
			continue
		case c == '\r':
			b := t.buf()
			b.col = 0
			b.wrapNext = false
		case c == '\n', c == 0x0b, c == 0x0c:
			t.lineFeed()
		case c == '\b':
			b := t.buf()
			b.wrapNext = false
			if b.col > 0 {
				b.col--
			}
		case c == '\t':
			b := t.buf()
			b.col = min(t.width-1, (b.col/8+1)*8)
		case c < 0x20 || c == 0x7f:
			// Other control bytes do not draw anything.
		default:
			r, size := utf8.DecodeRune(data[i:])
			text := string(data[i : i+size])
			if r == utf8.RuneError && size == 1 {
				text = "?"
			}
			t.put(text, min(2, ansi.StringWidth(text)))
			i += size
			continue
		}
		i++
	}
}

// escape handles the sequence after ESC at data[i] and returns where the
// next byte starts.
func (t *terminal) escape(data []byte, i int) int {
	if i >= len(data) {
		return i
	}
	switch data[i] {
	case '[':
		j := i + 1
		var private byte
		if j < len(data) && (data[j] == '?' || data[j] == '>' || data[j] == '<' || data[j] == '=') {
			private = data[j]
			j++
		}
		start := j
		for j < len(data) && (data[j] >= '0' && data[j] <= '9' || data[j] == ';' || data[j] == ':') {
			j++
		}
		raw := strings.ReplaceAll(string(data[start:j]), ":", ";")
		// Intermediate bytes, such as the space in "CSI 2 SP q", are skipped.
		for j < len(data) && data[j] >= 0x20 && data[j] <= 0x2f {
			j++
		}
		if j >= len(data) {
			return j
		}
		t.csi(private, raw, data[j])
		return j + 1
	case ']', 'P', '_', '^':
		// OSC, DCS and the like run to BEL or ESC \; their text is not shown.
		for j := i + 1; j < len(data); j++ {
			if data[j] == 0x07 {
				return j + 1
			}
			if data[j] == 0x1b && j+1 < len(data) && data[j+1] == '\\' {
				return j + 2
			}
		}
		return len(data)
	case '(', ')', '*', '+', '#', '%':
		return i + 2
	case '7':
		t.saveCursor()
	case '8':
		t.restoreCursor()
	case 'D':
		t.lineFeed()
	case 'E':
		t.buf().col = 0
		t.lineFeed()
	case 'M':
		b := t.buf()
		if b.row > 0 {
			b.row--
		} else {
			t.insertLines(1)
		}
	case 'c':
		*t = *newTerminal(t.width, t.height)
	}
	return i + 1
}

// Screen returns the rows on screen now, with their colors, from the
// alternate screen while a command uses it.
func (t *terminal) Screen() []string {
	b := t.buf()
	rows := make([]string, t.height)
	for r := range rows {
		if i := b.top + r; i < len(b.lines) {
			rows[r] = renderCells(b.lines[i])
		}
	}
	return rows
}

// Cursor returns the cursor's screen row and column, and whether it shows.
func (t *terminal) Cursor() (row, col int, visible bool) {
	b := t.buf()
	return b.row, b.col, !t.cursorHidden
}

// Resize follows a new window size. Lines keep their text; the cursor
// keeps its line, which stays on screen.
func (t *terminal) Resize(width, height int) {
	width, height = max(1, width), max(1, height)
	for _, b := range []*buffer{&t.main, t.alt} {
		if b == nil {
			continue
		}
		if b.row >= height {
			shift := b.row - height + 1
			if b == t.alt {
				b.lines = b.lines[min(shift, len(b.lines)):]
			} else {
				b.top += shift
			}
			b.row -= shift
		}
		if b == t.alt && len(b.lines) > height {
			// The alternate screen holds exactly one screen.
			b.lines = b.lines[:height]
		}
		b.col = min(b.col, width-1)
		b.wrapNext = false
	}
	t.width, t.height = width, height
	t.ensureRow(t.buf(), t.buf().row)
}

// Lines returns the output, history first, with each line's colors as SGR
// sequences and trailing blank lines dropped.
func (t *terminal) Lines() []string {
	out := make([]string, 0, len(t.main.lines))
	for _, l := range t.main.lines {
		out = append(out, renderCells(l))
	}
	return trimBlankEnd(out)
}

func trimBlankEnd(lines []string) []string {
	for len(lines) > 0 && strings.TrimSpace(ansi.Strip(lines[len(lines)-1])) == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func renderCells(l []cell) string {
	// Trailing blanks in the default style carry nothing.
	end := len(l)
	for end > 0 && (l[end-1].text == " " || l[end-1].text == "") && l[end-1].style == "" {
		end--
	}
	var sb strings.Builder
	style := ""
	for _, c := range l[:end] {
		if c.style != style {
			sb.WriteString("\x1b[0m")
			if c.style != "" {
				sb.WriteString("\x1b[" + c.style + "m")
			}
			style = c.style
		}
		sb.WriteString(c.text)
	}
	if style != "" {
		sb.WriteString("\x1b[0m")
	}
	return sb.String()
}

// sgr is the set of character attributes in effect.
type sgr struct {
	bold, dim, italic, underline, blink, reverse, hidden, strike bool
	fg, bg                                                       string
}

func (s *sgr) apply(p []int) {
	if len(p) == 0 {
		*s = sgr{}
		return
	}
	for i := 0; i < len(p); i++ {
		n := p[i]
		switch {
		case n <= 0:
			*s = sgr{}
		case n == 1:
			s.bold = true
		case n == 2:
			s.dim = true
		case n == 3:
			s.italic = true
		case n == 4:
			s.underline = true
		case n == 5 || n == 6:
			s.blink = true
		case n == 7:
			s.reverse = true
		case n == 8:
			s.hidden = true
		case n == 9:
			s.strike = true
		case n == 21 || n == 22:
			s.bold, s.dim = false, false
		case n == 23:
			s.italic = false
		case n == 24:
			s.underline = false
		case n == 25:
			s.blink = false
		case n == 27:
			s.reverse = false
		case n == 28:
			s.hidden = false
		case n == 29:
			s.strike = false
		case n >= 30 && n <= 37, n >= 90 && n <= 97:
			s.fg = strconv.Itoa(n)
		case n == 39:
			s.fg = ""
		case n >= 40 && n <= 47, n >= 100 && n <= 107:
			s.bg = strconv.Itoa(n)
		case n == 49:
			s.bg = ""
		case n == 38 || n == 48:
			color, used := extendedColor(p[i+1:])
			if color != "" {
				if n == 38 {
					s.fg = "38;" + color
				} else {
					s.bg = "48;" + color
				}
			}
			i += used
		}
	}
}

// extendedColor reads "5;n" or "2;r;g;b" and returns it with how many
// parameters it used.
func extendedColor(p []int) (string, int) {
	if len(p) >= 2 && p[0] == 5 {
		return "5;" + strconv.Itoa(max(0, p[1])), 2
	}
	if len(p) >= 4 && p[0] == 2 {
		return "2;" + strconv.Itoa(max(0, p[1])) + ";" + strconv.Itoa(max(0, p[2])) + ";" + strconv.Itoa(max(0, p[3])), 4
	}
	return "", len(p)
}

func (s sgr) code() string {
	var parts []string
	for _, f := range []struct {
		on   bool
		code string
	}{
		{s.bold, "1"}, {s.dim, "2"}, {s.italic, "3"}, {s.underline, "4"},
		{s.blink, "5"}, {s.reverse, "7"}, {s.hidden, "8"}, {s.strike, "9"},
	} {
		if f.on {
			parts = append(parts, f.code)
		}
	}
	if s.fg != "" {
		parts = append(parts, s.fg)
	}
	if s.bg != "" {
		parts = append(parts, s.bg)
	}
	return strings.Join(parts, ";")
}
