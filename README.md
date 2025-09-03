# build-helium

🧪 **Auto-tunes Gradle & Kotlin daemon settings for your machine.**  
Benchmarks different heap sizes & worker counts, finds the sweet spot, and enforces it globally via a Gradle init script — **no project edits required**.

---

## Why?

Large Android/Gradle projects often waste memory or time because the defaults are:
- too big → wasted RAM, disabled **CompressedOops**, code cache bloat
- too small → GC thrash, scheduler contention

**build-helium** runs a repeatable benchmark, scores candidates, and writes an optimized configuration for your machine. From then on, every Gradle build (CLI or Android Studio, any worktree) uses those tuned values.

---

## Features

- 🔍 **Automatic benchmarking** (wall time, peak RSS, GC %)
- ⚡ **Picks optimal** heap sizes & workers for Gradle and Kotlin daemons
- 🌍 **Global init script** applies settings everywhere (no touching `gradle.properties`)
- 🧱 **Synthetic heavy task** (`heliumBenchmark`) for repeatable benchmarking
- 👩‍💻 Works across **multiple worktrees / IDE instances**
- 🛑 Keeps heap **< 32 GB** to preserve **CompressedOops**
- 🐧 **macOS + Linux** support
- 📄 **Reports**: writes canonical **JSON**, plus pretty **Markdown** and **HTML**

---

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/EtienneBBeaulac/build-helium/main/install.sh | bash
```

This will:
	•	Copy the CLI helium-tune into ~/bin
	•	Install two Gradle init scripts into ~/.gradle/init.d/:
	•	gradle-tuner.init.gradle.kts (enforces chosen config)
	•	helium-benchmark.init.gradle.kts (adds synthetic benchmark tasks)
	•	Create ~/.gradle/gradle-tuner.json to store your tuned settings

Uninstall:
```bash
curl -fsSL https://raw.githubusercontent.com/EtienneBBeaulac/build-helium/main/uninstall.sh | bash
```

⸻

Usage

Run the tuner (synthetic)

helium-tune

	•	By default, tunes against the synthetic heliumBenchmark task.
	•	Tries several candidate configs, scores them, and persists the winner to ~/.gradle/gradle-tuner.json.
	•	Writes reports to ~/.gradle/build-helium/reports/:
	•	report-YYYYMMDDTHHMMSSZ.json (canonical data)
	•	Matching .md and .html
	•	Convenience copies: latest.json, latest.md, latest.html

Open the latest HTML report:
```bash
open ~/.gradle/build-helium/reports/latest.html   # macOS
# xdg-open ~/.gradle/build-helium/reports/latest.html  # Linux
```

Tune against a real task (recommended)
```bash
helium-tune ':app:assembleDebug'
# or
helium-tune testDebugUnitTest
```

Flags
	•	--big → uses heliumBenchmarkBig (heavier synthetic workload)
	•	--report-dir <dir> → where to write reports
	•	--no-md / --no-html / --json-only
	•	--tag <string> → suffix added to report filenames

Adjust scoring weights (optional)
```bash
# Defaults shown; override per run:
W_T=1.0      # weight for wall time (seconds)
W_R=0.00001  # weight for RSS KB penalty
W_G=5.0      # weight for GC% penalty

W_R=0.00002 helium-tune ':app:assembleDebug'
```

⸻

Synthetic benchmark tasks

Installed automatically, available in every Gradle build:
	•	heliumBenchmark — default synthetic task (CPU + allocations + optional I/O)
	•	heliumBenchmarkBig — heavier preset

Run directly:
```bash
./gradlew heliumBenchmark
./gradlew heliumBenchmarkBig
```
Customize size:
```bash
./gradlew heliumBenchmark \
  -Phelium.actions=400 \
  -Phelium.repeats=150 \
  -Phelium.sizeKB=128 \
  -Phelium.useDisk=false \
  -Phelium.deterministic=true
```
What it does:
	•	Spawns lots of Gradle workers
	•	Generates payloads (optionally writes inputs to disk), does repeated SHA-256 hashing, writes outputs
	•	Disables caching to force real work every run
	•	Stresses heap, GC, and worker parallelism in a repeatable way

⸻

How it works
	1.	Candidates: chooses heap sizes & worker counts based on your cores/RAM
(e.g., 4g/6g/8g for Gradle, 2g/3g/4g for Kotlin; workers ≤ cores)
	2.	Benchmark: for each candidate, runs your task and measures:
	•	Wall time (/usr/bin/time -l on macOS, -v on GNU time)
	•	Peak RSS (from time)
	•	GC % (from -Xlog:gc* logs)
	3.	Score:
```
score = (time * W_T) + (RSS_KB * W_R) + ((GC% / 100) * W_G)
```
Lowest score wins.

	4.	Persist config: writes to ~/.gradle/gradle-tuner.json
	5.	Enforce globally: gradle-tuner.init.gradle.kts loads JSON and sets:
	•	org.gradle.jvmargs
	•	kotlin.daemon.jvmargs
	•	org.gradle.workers.max

⸻

Verify

After tuning, check active daemons:
```bash
./gradlew --status
jps -lv | grep GradleDaemon
PID=$(jps -lv | awk '/GradleDaemon/ {print $1; exit}')
jcmd $PID VM.flags | grep -E "MaxHeapSize|UseCompressedOops"
```
You should see:
	•	MaxHeapSize at the tuned value (e.g., 4294967296 for -Xmx4g)
	•	UseCompressedOops = true

⸻

Limitations
	•	Benchmarks are local to your machine and repo.
	•	The synthetic task is a great baseline—validate with a real task too.
	•	Requires /usr/bin/time with -l (macOS) or GNU time with -v (Linux).
	•	Needs Python 3 (or python) available for tiny arithmetic snippets.

⸻

Roadmap
	•	Windows support
	•	Richer HTML charts (sparklines for wall/RSS/GC)
	•	Profiles per project & Gradle version
	•	Homebrew tap
	•	CI integration (run once, commit tuned JSON)

⸻

License

MIT — do what you want, just credit.

⸻

Example session
Cleanup

During runs with disk I/O enabled, temporary inputs/outputs are created under `build/helium/{inputs,outputs}`.

- Clean via Gradle task (all projects):
```bash
./gradlew heliumClean
```
- Or use the CLI helper:
```bash
helium-clean
```

Auto-clean: normal runs of `heliumBenchmark` and `heliumBenchmarkBig` finalize with `heliumClean`. A hard interrupt (Ctrl+C) may stop the build before finalizers; in that case, run one of the clean commands above.

```bash
$ helium-tune
build-helium: 12 cores, 64 GB RAM
Task: heliumBenchmark
Candidates:
  4g 2g 6
  6g 3g 6
  8g 4g 6
== G4g_K2g_W6 ==
  -> WALL=68.2 RSS_KB=3150000 GC_PCT=2.1
  -> score=68.5
== G6g_K3g_W6 ==
  -> WALL=61.7 RSS_KB=4950000 GC_PCT=1.9
  -> score=62.2
== G8g_K4g_W6 ==
  -> WALL=62.3 RSS_KB=7200000 GC_PCT=1.8
  -> score=63.0

Winner: G6g_K3g_W6
  wall=61.7s rss=4950000KB gc=1.9%
  gradleXmx=6g kotlinXmx=3g workers=6

Reports:
  ~/.gradle/build-helium/reports/latest.json
  ~/.gradle/build-helium/reports/latest.md
  ~/.gradle/build-helium/reports/latest.html
```
