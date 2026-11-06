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

// pinFooterToBottom puts the frame's last line, the keys, on the window's
// last row, where Analyze and the command screen keep theirs; the blank lines
// go between the cards and the keys instead of under the keys. A frame as tall
// as the window is left as it is.
func pinFooterToBottom(view string, height int) string {
	lines := lipgloss.Height(view)
	if height <= 0 || lines >= height {
		return view
	}
	last := strings.LastIndex(view, "\n")
	if last < 0 {
		return padViewToHeight(view, height)
	}
	return view[:last] + strings.Repeat("\n", height-lines+1) + view[last+1:]
}

// renderStatusFooter lists the keys, with the current time between refreshes.
func renderStatusFooter(refresh time.Duration) string {
	return subtleStyle.Render(fmt.Sprintf("R refresh %gs  ·  C cores  ·  K cat  ·  Q quit", refresh.Seconds()))
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
