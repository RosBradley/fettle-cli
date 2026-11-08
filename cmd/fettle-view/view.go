package main

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// Colors match Mole's shell UI; NO_COLOR turns them off.
var (
	titleStyle  = "\x1b[1;35m"
	grayStyle   = "\x1b[0;38;5;244m"
	greenStyle  = "\x1b[0;32m"
	yellowStyle = "\x1b[0;33m"
	markStyle   = "\x1b[7m" // a search match
	resetStyle  = "\x1b[0m"
)

func init() {
	if os.Getenv("NO_COLOR") != "" {
		titleStyle, grayStyle, greenStyle, yellowStyle, markStyle, resetStyle = "", "", "", "", "", ""
	}
}

type page int

const (
	outputPage page = iota
	filePage
)

// model shows the command's output, its summary pinned at the top, and, on
// F, the file list it wrote. The bar at the bottom says how the command
// ended and which keys work; / searches the page shown.
type model struct {
	title     string
	status    string // how the command ended, for the bar
	output    []string
	summary   []string
	filePath  string
	fileLines []string // as read; wrapped to the width when shown
	page      page
	offset    [2]int // first shown line on each page
	width     int
	height    int
	query     string // the search on the page shown; "" shows every line
	typing    bool   // keys go to the search line
	before    int    // where the page was before the search, to go back to
}

func newModel(title string, output []string, code int, filePath string, fileLines []string, width, height int) model {
	rest, summary := splitSummary(output)
	if filePath != "" {
		// Point at F from the summary line that names the file.
		for i, s := range summary {
			if strings.Contains(ansi.Strip(s), filePath) {
				summary[i] = s + grayStyle + "  (F to view)" + resetStyle
			}
		}
	}
	m := model{title: title, status: finishStatus(summary, code), output: rest, summary: summary,
		filePath: filePath, fileLines: fileLines, width: width, height: height}
	m.offset[outputPage] = m.maxOffset() // what the command did last is at the end
	return m
}

// finishStatus says how the command ended: its summary's heading, or that it
// is done, marked by its exit status.
func finishStatus(summary []string, code int) string {
	heading := ""
	if len(summary) > 0 {
		heading = strings.TrimSpace(ansi.Strip(summary[0]))
	}
	switch {
	case code == 0 && heading != "":
		return greenStyle + "✓ " + heading + resetStyle
	case code == 0:
		return greenStyle + "✓ Done" + resetStyle
	case code == 130 || code < 0:
		return yellowStyle + "■ Stopped" + resetStyle
	case heading != "":
		return yellowStyle + "! " + heading + resetStyle
	default:
		return yellowStyle + fmt.Sprintf("! Ended with an error (exit status %d)", code) + resetStyle
	}
}

func (m model) Init() tea.Cmd { return nil }

// all is every line the page has, before any search.
func (m model) all() []string {
	if m.page == filePage {
		return m.fileLines
	}
	return m.output
}

// lines is what the page shows: the lines that match the search, with the
// match marked, and the file list wrapped to the width.
func (m model) lines() []string {
	var out []string
	for _, l := range m.all() {
		if m.query != "" {
			var ok bool
			if l, ok = mark(l, m.query); !ok {
				continue
			}
		}
		if m.page == filePage {
			l = strings.ReplaceAll(l, "\t", "    ")
			if l != "" {
				out = append(out, strings.Split(ansi.Wrap(l, max(1, m.width), "/"), "\n")...)
				continue
			}
		}
		out = append(out, l)
	}
	return out
}

// mark reports whether line contains query, upper or lower case alike, and
// returns it with each match marked. A marked line loses its colors.
func mark(line, query string) (string, bool) {
	if query == "" {
		return line, true
	}
	plain := ansi.Strip(line)
	lower, q := strings.ToLower(plain), strings.ToLower(query)
	if !strings.Contains(lower, q) {
		return line, false
	}
	if len(lower) != len(plain) {
		return plain, true // lowercase changed the byte offsets; show it unmarked
	}
	var sb strings.Builder
	for {
		i := strings.Index(lower, q)
		if i < 0 {
			break
		}
		sb.WriteString(plain[:i] + markStyle + plain[i:i+len(q)] + resetStyle)
		plain, lower = plain[i+len(q):], lower[i+len(q):]
	}
	sb.WriteString(plain)
	return sb.String(), true
}

// pinned is the summary shown above the output; the file list shows none.
func (m model) pinned() []string {
	if m.page == filePage {
		return nil
	}
	return m.summary
}

// bodyHeight leaves the rows above the output (the title, the summary and a
// divider) and below it (a divider and the bar).
func (m model) bodyHeight() int { return max(1, m.height-4-len(m.pinned())) }

func (m model) maxOffset() int { return max(0, len(m.lines())-m.bodyHeight()) }

func (m *model) scroll(delta int) {
	m.offset[m.page] = max(0, min(m.offset[m.page]+delta, m.maxOffset()))
}

// search sets the search; matches show from the first one, and an empty
// search goes back to where the page was.
func (m *model) search(query string) {
	if m.query == "" && query != "" {
		m.before = m.offset[m.page]
	}
	m.query = query
	if query == "" {
		m.offset[m.page] = m.before
	} else {
		m.offset[m.page] = 0
	}
	m.scroll(0)
}

func (m *model) clearSearch() {
	if m.query == "" && !m.typing {
		return
	}
	m.typing = false
	m.search("")
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		atEnd := m.offset[m.page] >= m.maxOffset()
		m.width, m.height = msg.Width, msg.Height
		if atEnd && m.page == outputPage && m.query == "" {
			m.offset[m.page] = m.maxOffset()
		}
		m.scroll(0)
		return m, nil
	case tea.KeyMsg:
		// Keys typed faster than they are read arrive together.
		if msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
			var cmd tea.Cmd
			var next tea.Model = m
			for _, r := range msg.Runes {
				next, cmd = next.(model).Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
				if cmd != nil {
					return next, cmd
				}
			}
			return next, nil
		}
		if m.typing {
			switch msg.Type {
			case tea.KeyRunes:
				m.search(m.query + string(msg.Runes))
				return m, nil
			case tea.KeySpace:
				m.search(m.query + " ")
				return m, nil
			case tea.KeyBackspace:
				if r := []rune(m.query); len(r) > 0 {
					m.search(string(r[:len(r)-1]))
				}
				return m, nil
			case tea.KeyCtrlU:
				m.search("")
				return m, nil
			case tea.KeyEnter:
				m.typing = false
				return m, nil
			case tea.KeyEsc:
				m.clearSearch()
				return m, nil
			case tea.KeyCtrlC:
				return m, tea.Quit
			case tea.KeyUp, tea.KeyDown, tea.KeyPgUp, tea.KeyPgDown, tea.KeyHome, tea.KeyEnd:
				m.typing = false // the arrows take the keys back to the page
			default:
				return m, nil
			}
		}
		page := m.bodyHeight()
		switch msg.String() {
		case "up", "k":
			m.scroll(-1)
		case "down", "j":
			m.scroll(1)
		case "pgup", "b", "left":
			m.scroll(-page)
		case "pgdown", " ", "right":
			m.scroll(page)
		case "home", "g":
			m.offset[m.page] = 0
		case "end", "G":
			m.offset[m.page] = m.maxOffset()
		case "/":
			if m.query == "" {
				m.before = m.offset[m.page]
			}
			m.typing = true
		case "f", "F":
			if m.page == outputPage && m.filePath != "" {
				m.clearSearch()
				m.page = filePage
				m.scroll(0)
			}
		case "q", "Q", "esc", "enter":
			if m.query != "" {
				m.clearSearch() // back from the search first
				return m, nil
			}
			if m.page == filePage {
				m.page = outputPage
				return m, nil
			}
			return m, tea.Quit
		case "ctrl+c":
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m model) View() string {
	width := max(1, m.width)
	lines := m.lines()
	body := m.bodyHeight()
	first := m.offset[m.page]
	last := min(len(lines), first+body)

	title := m.title
	if m.page == filePage {
		title = "File list: " + tildePath(m.filePath)
	}
	position := ""
	if len(lines) > body {
		position = fmt.Sprintf("%d-%d of %d", first+1, last, len(lines))
	}

	rows := topRows(title, position, m.pinned(), width)
	for i := first; i < first+body; i++ {
		row := ""
		switch {
		case i < last:
			row = ansi.Truncate(lines[i], width, "…")
		case i == 0 && m.query != "":
			row = grayStyle + "No matches" + resetStyle
		}
		rows = append(rows, row)
	}
	rows = append(rows, bottomRows(m.bar(width), width)...)
	return strings.Join(rows, "\n")
}

// bar is the bottom row: how the command ended, or the search, and the
// keys, dropping the less needed ones when space runs out.
func (m model) bar(width int) string {
	found := ""
	if m.query != "" {
		found = fmt.Sprintf("%d matching lines", m.matchCount())
		if m.matchCount() == 1 {
			found = "1 matching line"
		}
	}
	switch {
	case m.typing && m.query == "":
		return fitBar(yellowStyle+"/ Search: _"+resetStyle, []string{"type to search", "Esc Cancel"}, []string{"type to search"}, width)
	case m.typing:
		return fitBar(yellowStyle+"/ Search: "+m.query+"_  "+resetStyle+grayStyle+found+resetStyle,
			[]string{"Enter Done", "Esc Clear"}, []string{"Enter Done"}, width)
	case m.query != "":
		return fitBar(yellowStyle+"/ "+m.query+resetStyle+"  "+grayStyle+found+resetStyle,
			[]string{"↑↓ Scroll", "/ Edit", "Esc Clear"}, []string{"↑↓ Scroll", "/ Edit"}, width)
	}
	back := "Q Back to menu"
	status := m.status
	if m.page == filePage {
		back, status = "Q Back to results", ""
	}
	keys := []string{"↑↓ Scroll", "PgUp PgDn Page", "Home End", "/ Search"}
	if m.page == outputPage && m.filePath != "" {
		keys = append(keys, "F File list")
	}
	keys = append(keys, back)
	return fitBar(status, keys, []string{"Home End", "PgUp PgDn Page", "↑↓ Scroll", "/ Search"}, width)
}

// matchCount is how many lines of the page match, before wrapping.
func (m model) matchCount() int {
	n := 0
	for _, l := range m.all() {
		if _, ok := mark(l, m.query); ok {
			n++
		}
	}
	return n
}

func tildePath(path string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" && strings.HasPrefix(path, home+"/") {
		return "~" + strings.TrimPrefix(path, home)
	}
	return path
}
