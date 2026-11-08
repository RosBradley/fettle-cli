package main

import (
	"slices"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// fettleSnapshot is a 16-core Apple-silicon Mac with one internal disk.
func fettleSnapshot() MetricsSnapshot {
	perCore := make([]float64, 16)
	for i := range perCore {
		perCore[i] = float64(i * 6)
	}
	return MetricsSnapshot{
		CPU: CPUStatus{Usage: 8.1, PerCore: perCore, Load1: 1.66, Load5: 2.6, Load15: 2.76,
			CoreCount: 16, LogicalCPU: 16, PCoreCount: 12, ECoreCount: 4},
		GPU:    []GPUStatus{{Name: "Apple M4 Max", Usage: 17, CoreCount: 40}},
		Memory: MemoryStatus{Used: 54 << 30, Total: 128 << 30, UsedPercent: 42.8},
		Disks: []DiskStatus{{Mount: "/", Used: 1100 << 30, Total: 1800 << 30, UsedPercent: 61.1},
			{Mount: "/Volumes/X", Used: 18 << 30, Total: 19 << 30, UsedPercent: 97.5, External: true}},
	}
}

func withCardWidth(t *testing.T, width int) {
	t.Helper()
	saved := statusCardWidth
	statusCardWidth = width
	t.Cleanup(func() { statusCardWidth = saved })
}

func withGPUCardPlatform(t *testing.T, platform string) {
	t.Helper()
	saved := gpuCardPlatform
	gpuCardPlatform = platform
	t.Cleanup(func() { gpuCardPlatform = saved })
}

func TestStatusBarWidthFillsTheCard(t *testing.T) {
	withCardWidth(t, 0)
	if got := statusBarWidth(); got != classicBarWidth {
		t.Fatalf("no card width: bar = %d, want the classic %d", got, classicBarWidth)
	}
	for _, tc := range []struct{ card, want int }{
		{30, classicBarWidth}, // never narrower than before
		{76, 76 - barLabelRoom - barValueRoom},
		{400, maxBarWidth},
	} {
		statusCardWidth = tc.card
		if got := statusBarWidth(); got != tc.want {
			t.Errorf("card %d: bar = %d, want %d", tc.card, got, tc.want)
		}
	}
	statusCardWidth = 76
	if got := lipgloss.Width(diskProgressBar(50)); got != 76-barLabelRoom-diskValueRoom {
		t.Errorf("disk bar = %d cells, want %d", got, 76-barLabelRoom-diskValueRoom)
	}
	if got := lipgloss.Width(classicProgressBar(50)); got != classicBarWidth {
		t.Errorf("process bar = %d cells, want the classic %d", got, classicBarWidth)
	}
	if statusValueRoom != barValueRoom {
		t.Errorf("diskProgressBar left statusValueRoom at %d", statusValueRoom)
	}
}

// Wider bars must never push a line past its card, where it would wrap. From
// 47 columns a disk line fits a classic bar; narrower cards keep Mole's own
// behaviour.
func TestStretchedCardLinesFitTheirCard(t *testing.T) {
	withGPUCardPlatform(t, "darwin")
	for _, width := range []int{47, 60, 76, 120} {
		withCardWidth(t, width)
		for _, card := range buildCards(fettleSnapshot(), width, 0, true) {
			for _, line := range card.lines {
				if got := lipgloss.Width(line); got > width {
					t.Errorf("card width %d: %s line is %d wide: %q", width, card.title, got, line)
				}
			}
		}
	}
}

func TestStatusShowsAllCoresAndAGPUCard(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	withGPUCardPlatform(t, "darwin")
	cores := loadCPUCores()
	if cores != 0 {
		t.Fatalf("default cpu cores = %d, want 0 (all)", cores)
	}
	cards := buildCards(fettleSnapshot(), 76, cores, true)
	var cpu, gpu string
	for _, card := range cards {
		switch card.title {
		case "CPU":
			cpu = strings.Join(card.lines, "\n")
		case "GPU":
			gpu = stripANSI(strings.Join(card.lines, "\n"))
		}
	}
	if got := strings.Count(cpu, "Core"); got != 16 {
		t.Errorf("CPU card lists %d cores, want all 16", got)
	}
	if !strings.Contains(gpu, "17.0%") || !strings.Contains(gpu, "Apple M4 Max · 40 cores") {
		t.Errorf("GPU card = %q", gpu)
	}
}

func TestGPUCardWhenUsageIsUnknownOrMissing(t *testing.T) {
	withGPUCardPlatform(t, "darwin")
	card, ok := renderGPUCard([]GPUStatus{{Name: "Apple M4", Usage: -1, CoreCount: 10}})
	if !ok || !strings.Contains(stripANSI(strings.Join(card.lines, "\n")), "not available") {
		t.Errorf("unknown usage: ok=%v lines=%q", ok, card.lines)
	}
	if _, ok := renderGPUCard(nil); ok {
		t.Error("no GPU: card shown")
	}
	if _, ok := renderGPUCard([]GPUStatus{{Usage: -1}}); ok {
		t.Error("nothing known about the GPU: card shown")
	}
	withGPUCardPlatform(t, "linux")
	if _, ok := renderGPUCard([]GPUStatus{{Name: "x", Usage: 5, CoreCount: 4}}); ok {
		t.Error("card shown off macOS")
	}
}

func TestParseIORegGPUUtilization(t *testing.T) {
	out := `+-o AGXAcceleratorG16X  <class AGXAcceleratorG16X>
    {
      "PerformanceStatistics" = {"In use system memory"=1234,"Device Utilization %"=23,"Renderer Utilization %"=21}
    }`
	if got := parseIORegGPUUtilization(out); got != 23 {
		t.Errorf("got %v, want 23", got)
	}
	if got := parseIORegGPUUtilization(`"Tiler Utilization %"=21`); got != -1 {
		t.Errorf("neither key: got %v, want -1", got)
	}
	if got := parseIORegGPUUtilization(`"Device Utilization %"=140`); got != 100 {
		t.Errorf("out of range: got %v, want 100", got)
	}
}

func TestParseIORegGPUUtilizationTakesTheBusiestAccelerator(t *testing.T) {
	out := `{"PerformanceStatistics" = {"Device Utilization %"=0}}
{"PerformanceStatistics" = {"Device Utilization %"=87,"Renderer Utilization %"=80}}`
	if got := parseIORegGPUUtilization(out); got != 87 {
		t.Errorf("got %v, want 87 from the busy accelerator", got)
	}
	if got := parseIORegGPUUtilization(`"Renderer Utilization %"=42`); got != 42 {
		t.Errorf("renderer only: got %v, want 42", got)
	}
}

func resetLiveGPU(t *testing.T, reader func() float64) {
	t.Helper()
	savedReader := readLiveGPUUsage
	readLiveGPUUsage = reader
	liveGPU.at, liveGPU.usage = time.Time{}, 0
	t.Cleanup(func() {
		readLiveGPUUsage = savedReader
		liveGPU.at, liveGPU.usage = time.Time{}, 0
	})
}

func TestRefreshLiveGPUUsageUpdatesEveryRefresh(t *testing.T) {
	withGPUCardPlatform(t, "darwin")
	reads := 0
	readings := []float64{12, 95, -1}
	resetLiveGPU(t, func() float64 {
		value := readings[min(reads, len(readings)-1)]
		reads++
		return value
	})

	start := time.Now()
	full := []GPUStatus{{Name: "Apple M4 Max", Usage: 3, CoreCount: 40}}
	snapshot := MetricsSnapshot{GPU: full}
	refreshLiveGPUUsage(&snapshot, start)
	if snapshot.GPU[0].Usage != 12 || full[0].Usage != 3 {
		t.Fatalf("first refresh: usage %v (full refresh's copy %v), want 12 and untouched 3", snapshot.GPU[0].Usage, full[0].Usage)
	}

	// Within the TTL the cached reading is reused, then a new one is taken.
	snapshot = MetricsSnapshot{GPU: slices.Clone(full)}
	refreshLiveGPUUsage(&snapshot, start.Add(100*time.Millisecond))
	if reads != 1 || snapshot.GPU[0].Usage != 12 {
		t.Fatalf("within TTL: reads=%d usage=%v, want 1 and 12", reads, snapshot.GPU[0].Usage)
	}
	snapshot = MetricsSnapshot{GPU: slices.Clone(full)}
	refreshLiveGPUUsage(&snapshot, start.Add(time.Second))
	if snapshot.GPU[0].Usage != 95 {
		t.Fatalf("next second: usage %v, want 95", snapshot.GPU[0].Usage)
	}

	// No answer from ioreg keeps the full refresh's value.
	snapshot = MetricsSnapshot{GPU: slices.Clone(full)}
	refreshLiveGPUUsage(&snapshot, start.Add(2*time.Second))
	if snapshot.GPU[0].Usage != 3 {
		t.Fatalf("no reading: usage %v, want the full refresh's 3", snapshot.GPU[0].Usage)
	}
}

func TestRefreshLiveGPUUsageSkipsWithoutAGPUOrOffMacOS(t *testing.T) {
	resetLiveGPU(t, func() float64 { t.Fatal("read GPU use"); return -1 })
	withGPUCardPlatform(t, "darwin")
	refreshLiveGPUUsage(&MetricsSnapshot{}, time.Now())
	withGPUCardPlatform(t, "linux")
	refreshLiveGPUUsage(&MetricsSnapshot{GPU: []GPUStatus{{Usage: 1}}}, time.Now())
}

func TestRefreshIntervalCyclesAndPersists(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if got := loadRefreshInterval(); got != refreshInterval {
		t.Fatalf("default = %v, want Mole's %v", got, refreshInterval)
	}
	want := []time.Duration{2 * time.Second, 5 * time.Second, 10 * time.Second, 500 * time.Millisecond, time.Second}
	m := model{}
	for i, w := range want {
		next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'r'}})
		m = next.(model)
		if m.refreshEvery() != w || loadRefreshInterval() != w {
			t.Fatalf("press %d: refresh %v, saved %v, want %v", i+1, m.refreshEvery(), loadRefreshInterval(), w)
		}
	}
	savePref("refresh_interval", "3s")
	if got := loadRefreshInterval(); got != refreshInterval {
		t.Errorf("unknown saved value: %v, want the default", got)
	}
}

func TestRefreshIntervalSetsTheWaitAndShowsInTheFooter(t *testing.T) {
	withCardWidth(t, 0) // View sets the card width; restore it afterwards.
	m := model{refresh: 5 * time.Second}
	next, cmd := m.Update(collectionResult{mode: collectionFast, data: MetricsSnapshot{CollectedAt: time.Now()}})
	if cmd == nil {
		t.Fatal("no next tick scheduled")
	}
	m = next.(model)
	// After the first snapshot, the next wait is the chosen interval.
	if delay := m.schedule.recordCompletion(collectionResult{mode: collectionFast}, m.refreshEvery()); delay != 5*time.Second {
		t.Errorf("wait = %v, want 5s", delay)
	}
	if footer := stripANSI(renderStatusFooter(500*time.Millisecond, 60)); footer != strings.Repeat("─", 60)+"\nR Refresh 0.5s  |  C CPU cores  |  K Cat  |  Q Quit" {
		t.Errorf("footer = %q", footer)
	}
	// A narrow window drops K, then C, and only then cuts the keys, rather
	// than wrapping them.
	for width, want := range map[int]string{
		40: "R Refresh 1s  |  C CPU cores  |  Q Quit",
		30: "R Refresh 1s  |  Q Quit",
		20: "R Refresh 1s  |  Q …",
	} {
		if footer := stripANSI(renderStatusFooter(time.Second, width)); footer != strings.Repeat("─", width)+"\n"+want {
			t.Errorf("%d columns: footer = %q", width, footer)
		}
	}
	if !strings.Contains(stripANSI(m.View()), "R Refresh 5s") {
		t.Error("the frame does not show the footer")
	}
}

func TestFastRefreshesSampleProcessesSoTheyNeverShowStale(t *testing.T) {
	now := time.Now()
	recent := collectionSchedule{hasSnapshot: true, lastFullAttemptAt: now, lastProcessAttemptAt: now}
	if mode := recent.nextMode(now.Add(500 * time.Millisecond)); mode != collectionFast {
		t.Fatalf("precondition: Mole's schedule gives %v half a second after a process sample", mode)
	}
	half := model{refresh: 500 * time.Millisecond, schedule: recent}
	if got := half.refreshMode(collectionFast); got != collectionProcess {
		t.Errorf("0.5s refresh: mode %v, want a process refresh", got)
	}
	if got := half.refreshMode(collectionFull); got != collectionFull {
		t.Errorf("0.5s refresh keeps the full refresh: got %v", got)
	}
	if got := (model{refresh: time.Second, schedule: recent}).refreshMode(collectionFast); got != collectionFast {
		t.Errorf("1s refresh: mode %v, want Mole's fast refresh unchanged", got)
	}
	// The very first refresh stays fast, so the first paint is quick.
	if got := (model{refresh: 500 * time.Millisecond}).refreshMode(collectionFast); got != collectionFast {
		t.Errorf("first refresh: mode %v, want fast", got)
	}
}

func TestKeysSitOnTheWindowsLastRow(t *testing.T) {
	withCardWidth(t, 0)
	for _, size := range []struct{ width, height int }{{120, 80}, {60, 90}, {200, 60}} {
		m := model{width: size.width, height: size.height, schedule: collectionSchedule{hasSnapshot: true}}
		view := m.View()
		lines := strings.Split(view, "\n")
		if len(lines) != size.height {
			t.Errorf("%dx%d: %d rows, want %d", size.width, size.height, len(lines), size.height)
			continue
		}
		if last := stripANSI(lines[len(lines)-1]); !strings.HasPrefix(last, "R Refresh") {
			t.Errorf("%dx%d: last row %q, want the keys", size.width, size.height, last)
		}
		if divider := stripANSI(lines[len(lines)-2]); divider != strings.Repeat("─", size.width) {
			t.Errorf("%dx%d: row above the keys %q, want a divider across the window", size.width, size.height, divider)
		}
		if strings.Count(stripANSI(view), "R Refresh") != 1 {
			t.Errorf("%dx%d: the keys show more than once", size.width, size.height)
		}
	}
	// A window too short for the cards shows its message, with no keys.
	short := model{width: 120, height: 5, schedule: collectionSchedule{hasSnapshot: true}}
	if lipgloss.Height(short.View()) != 5 {
		t.Error("a short window's frame isn't the window's height")
	}
}
