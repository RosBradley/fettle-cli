package main

// moremole: Status stretches its bars to fill the window, shows a GPU card,
// and lets R change how often it refreshes.
// Kept in its own file so upstream Mole updates merge with few conflicts; the
// other files only call into it.

import (
	"context"
	"fmt"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

const (
	classicBarWidth = 16
	maxBarWidth     = 64
	// Room in front of a bar for its label, as in "Total  ".
	barLabelRoom = metricLabelWidth + 1
	// Room after a bar for its value, as in "  100.0% @ 99.9°C".
	barValueRoom = 17
	// Disk lines end with "  1.8T used, 677G free".
	diskValueRoom   = 24
	ioregGPUTimeout = 1 * time.Second
	// A GPU reading is reused only within one refresh, even the fastest.
	liveGPUUsageTTL = 400 * time.Millisecond
)

// gpuCardPlatform is the platform the GPU card is shown on; tests replace it.
var gpuCardPlatform = runtime.GOOS

// statusCardWidth is the width of the cards being drawn, set by View for each
// frame. 0 keeps the classic bar width, as in tests and before the first frame.
var statusCardWidth int

// statusValueRoom is the room the line being drawn needs after its bar.
var statusValueRoom = barValueRoom

// statusBarWidth is the bar width that fills the card while leaving room for
// the line's label and value.
func statusBarWidth() int {
	if statusCardWidth <= 0 {
		return classicBarWidth
	}
	return min(max(statusCardWidth-barLabelRoom-statusValueRoom, classicBarWidth), maxBarWidth)
}

// barOfWidth draws a bar total cells wide, filled to percent.
func barOfWidth(percent float64, total int) string {
	percent = min(max(percent, 0), 100)
	filled := int(percent / 100 * float64(total))
	return strings.Repeat("█", filled) + strings.Repeat("░", total-filled)
}

// diskProgressBar is progressBar for disk lines, whose value text is longer.
func diskProgressBar(percent float64) string {
	saved := statusValueRoom
	statusValueRoom = diskValueRoom
	defer func() { statusValueRoom = saved }()
	return progressBar(percent)
}

// classicProgressBar keeps the original width, for process rows whose names
// need the rest of the line.
func classicProgressBar(percent float64) string {
	return colorizePercent(percent, barOfWidth(percent, classicBarWidth))
}

// renderGPUCard shows total GPU usage and the GPU's core count and name.
// macOS reports usage for the GPU as a whole, not for each GPU core.
func renderGPUCard(gpus []GPUStatus) (cardData, bool) {
	if gpuCardPlatform != "darwin" || len(gpus) == 0 {
		return cardData{}, false
	}
	gpu := gpus[0]
	if gpu.CoreCount <= 0 && gpu.Usage < 0 {
		return cardData{}, false
	}

	var lines []string
	if gpu.Usage >= 0 {
		lines = append(lines, fmt.Sprintf("%-*s %s  %5.1f%%", metricLabelWidth, "Usage", progressBar(gpu.Usage), gpu.Usage))
	} else {
		lines = append(lines, fmt.Sprintf("%-*s %s", metricLabelWidth, "Usage", subtleStyle.Render("not available")))
	}
	var about []string
	if gpu.Name != "" {
		about = append(about, gpu.Name)
	}
	if gpu.CoreCount > 0 {
		about = append(about, fmt.Sprintf("%d cores", gpu.CoreCount))
	}
	if len(about) > 0 {
		lines = append(lines, fmt.Sprintf("%-*s %s", metricLabelWidth, "Chip", strings.Join(about, " · ")))
	}
	return cardData{icon: iconGPU, title: "GPU", lines: lines}, true
}

var (
	gpuDeviceUtilizationRe   = regexp.MustCompile(`"Device Utilization %"\s*=\s*(\d+(?:\.\d+)?)`)
	gpuRendererUtilizationRe = regexp.MustCompile(`"Renderer Utilization %"\s*=\s*(\d+(?:\.\d+)?)`)
)

// parseIORegGPUUtilization reads GPU use from ioreg output: the highest
// "Device Utilization %" of any accelerator listed, since an idle one may come
// first, else the highest "Renderer Utilization %". -1 when neither is there.
func parseIORegGPUUtilization(out string) float64 {
	for _, re := range []*regexp.Regexp{gpuDeviceUtilizationRe, gpuRendererUtilizationRe} {
		usage := -1.0
		for _, matches := range re.FindAllStringSubmatch(out, -1) {
			if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
				usage = max(usage, value)
			}
		}
		if usage >= 0 {
			return min(usage, 100)
		}
	}
	return -1
}

// readLiveGPUUsage reads GPU use for the per-second refresh; tests replace it.
var readLiveGPUUsage = readIORegGPUUtilization

var liveGPU struct {
	sync.Mutex
	at    time.Time
	usage float64
}

// refreshLiveGPUUsage puts current GPU use into a snapshot from the
// per-second refresh. Without it GPU use came only from the full refresh,
// every 30 seconds, so a burst of GPU work between two of those never showed.
// Keeps the full refresh's value when ioreg has no answer.
func refreshLiveGPUUsage(snapshot *MetricsSnapshot, now time.Time) {
	if gpuCardPlatform != "darwin" || snapshot == nil || len(snapshot.GPU) == 0 {
		return
	}
	liveGPU.Lock()
	if liveGPU.at.IsZero() || now.Sub(liveGPU.at) >= liveGPUUsageTTL {
		liveGPU.usage = readLiveGPUUsage()
		liveGPU.at = now
	}
	usage := liveGPU.usage
	liveGPU.Unlock()
	if usage >= 0 {
		snapshot.GPU = slices.Clone(snapshot.GPU)
		snapshot.GPU[0].Usage = usage
	}
}

// readIORegGPUUtilization asks the GPU driver for its utilization. Unlike
// powermetrics it needs no administrator rights. Returns -1 when unavailable.
func readIORegGPUUtilization() float64 {
	if runtime.GOOS != "darwin" || !commandExists("ioreg") {
		return -1
	}
	ctx, cancel := context.WithTimeout(context.Background(), ioregGPUTimeout)
	defer cancel()
	out, err := runCmd(ctx, "ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator")
	if err != nil {
		return -1
	}
	return parseIORegGPUUtilization(out)
}

// refreshIntervals is the sequence the 'r' key steps through.
var refreshIntervals = []time.Duration{
	500 * time.Millisecond, time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second,
}

// refreshEvery is the time between refreshes, Mole's default when unset.
func (m model) refreshEvery() time.Duration {
	if m.refresh <= 0 {
		return refreshInterval
	}
	return m.refresh
}

// loadRefreshInterval reads the saved time between refreshes; an unset or
// unknown value gives Mole's default.
func loadRefreshInterval() time.Duration {
	d, err := time.ParseDuration(loadPrefs()["refresh_interval"])
	if err != nil || !slices.Contains(refreshIntervals, d) {
		return refreshInterval
	}
	return d
}

func saveRefreshInterval(d time.Duration) {
	savePref("refresh_interval", d.String())
}

// nextRefreshInterval returns the interval after current, wrapping around; an
// unknown current value restarts at the first.
func nextRefreshInterval(current time.Duration) time.Duration {
	i := slices.Index(refreshIntervals, current)
	return refreshIntervals[(i+1)%len(refreshIntervals)]
}

// statusFooterRows is how many rows renderStatusFooter takes: a divider and
// the keys.
const statusFooterRows = 2

// barKeyStyle is the gray the command screen and the menu draw their bottom
// bar in (256-color 244).
var barKeyStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))

// pinFooterToBottom puts the frame's last rows, the divider and the keys, at
// the bottom of the window, where the command screen, the menu and Analyze
// keep theirs; the blank lines go between the cards and the divider instead
// of under the keys. A frame as tall as the window is left as it is.
func pinFooterToBottom(view string, height int) string {
	lines := lipgloss.Height(view)
	if height <= 0 || lines >= height || lines <= statusFooterRows {
		return padViewToHeight(view, height)
	}
	cut := len(view)
	for range statusFooterRows {
		cut = strings.LastIndex(view[:cut], "\n")
	}
	return view[:cut] + strings.Repeat("\n", height-lines+1) + view[cut+1:]
}

// renderStatusFooter is the bottom bar, styled as the command screen's: a
// gray divider across the window, then the keys in gray, joined by "|", with
// the current time between refreshes. A narrow window drops K, then C, as
// the command screen drops its optional keys, before cutting what is left.
func renderStatusFooter(refresh time.Duration, width int) string {
	width = max(width, 1)
	keys := []string{fmt.Sprintf("R Refresh %gs", refresh.Seconds()), "C CPU cores", "K Cat", "Q Quit"}
	join := func() string {
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = barKeyStyle.Render(k)
		}
		return strings.Join(parts, "  |  ")
	}
	bar := join()
	for _, optional := range []string{"K Cat", "C CPU cores"} {
		if ansi.StringWidth(bar) <= width {
			break
		}
		keys = slices.DeleteFunc(keys, func(k string) bool { return k == optional })
		bar = join()
	}
	return barKeyStyle.Render(strings.Repeat("─", width)) + "\n" + ansi.Truncate(bar, width, "…")
}

// refreshMode makes a fast refresh also sample processes when refreshes come
// faster than Mole samples them (every second). A fast refresh shows the last
// process sample marked STALE, which at 0.5s flickered in on every other
// refresh and moved the screen.
func (m model) refreshMode(mode collectionMode) collectionMode {
	if mode == collectionFast && m.schedule.hasSnapshot && m.refreshEvery() < processWatchInterval {
		return collectionProcess
	}
	return mode
}
