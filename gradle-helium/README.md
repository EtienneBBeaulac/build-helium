[gradle-sweetspot]

🧪 Auto-tunes Gradle & Kotlin daemon settings for your machine.
Benchmarks different heap sizes & worker counts, finds the sweet spot, and enforces it globally via a Gradle init script — no project edits required.

⸻

Why?

Large Android/Gradle projects often waste memory or time because the default daemon settings are too big (wasting RAM, disabling compressed oops) or too small (thrashing GC).

gradle-sweetspot runs a repeatable benchmark, scores candidates, and writes an optimized configuration for your machine. From then on, every Gradle build (CLI or Android Studio, any worktree) will use those tuned values.

⸻

Features
	•	🔍 Benchmarks automatically (wall time, peak RSS, GC overhead)
	•	⚡ Picks optimal heap size & workers for Gradle and Kotlin daemons
	•	🌍 Global init script applies settings everywhere (no need to touch project gradle.properties)
	•	🧱 Includes a synthetic heavy task (sweetspotBenchmark) so you can benchmark without a real build target
	•	👩‍💻 Works across multiple worktrees / IDE instances
	•	🛑 Keeps heap <32 GB to preserve compressed oops (avoids pointer bloat)
	•	🐧 macOS + Linux support

⸻

Install

One-liner:

bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GH_USER/gradle-sweetspot/main/install.sh)"

This will:
	•	Copy the CLI tool gradle-tune into ~/bin
	•	Install two Gradle init scripts into ~/.gradle/init.d:
	•	gradle-tuner.init.gradle.kts (enforces chosen config)
	•	sweetspot-benchmark.init.gradle.kts (adds synthetic benchmark tasks)
	•	Create ~/.gradle/gradle-tuner.json to store your tuned settings

Uninstall:

bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GH_USER/gradle-sweetspot/main/uninstall.sh)"


⸻

Usage

Run the tuner

gradle-tune

	•	By default, it tunes against the synthetic sweetspotBenchmark task.
	•	It will run several candidate configs, score them, and persist the winner to ~/.gradle/gradle-tuner.json.

Use a real Gradle task

gradle-tune ':app:assembleDebug'

or

gradle-tune testDebugUnitTest

This is recommended after the synthetic benchmark — it ensures the chosen config matches your real build bottlenecks.

Flags
	•	--big → uses sweetspotBenchmarkBig (heavier synthetic workload)
	•	--help → prints usage/help

Tune weights (optional)

You can adjust the scoring function with environment variables:

W_T=1.0   # weight for wall time (seconds)
W_R=0.00001 # weight for RSS KB penalty
W_G=5.0   # weight for GC% penalty

Example:

W_R=0.00002 gradle-tune ':app:assembleDebug'


⸻

Synthetic Benchmark Task

Installed automatically, available in every Gradle build:
	•	sweetspotBenchmark — default synthetic task (CPU + allocations + I/O)
	•	sweetspotBenchmarkBig — heavier preset

Run directly:

./gradlew sweetspotBenchmark
./gradlew sweetspotBenchmarkBig

Customize size:

./gradlew sweetspotBenchmark \
  -Psweetspot.actions=400 \
  -Psweetspot.repeats=150 \
  -Psweetspot.sizeKB=128

What it does:
	•	Spawns hundreds of Gradle workers
	•	Generates random files, does repeated SHA-256 hashing, writes results
	•	Disables caching to force real work every run
	•	Designed to stress heap, GC, and worker parallelism

⸻

How it works
	1.	Candidate configs: chooses heap sizes & worker counts based on your cores/RAM
(e.g. 4g/6g/8g for Gradle, 2g/3g/4g for Kotlin, workers ≤ cores)
	2.	Benchmark runs: runs your chosen task with each candidate, measuring:
	•	Wall clock time (/usr/bin/time -l)
	•	Peak RSS (from time)
	•	GC overhead (from -Xlog:gc* logs)
	3.	Scoring:

score = (time * W_T) + (RSS_KB * W_R) + (GC% * W_G)

Lowest score wins.

	4.	Persist config: writes to ~/.gradle/gradle-tuner.json
	5.	Enforce config: gradle-tuner.init.gradle.kts loads the JSON and sets:
	•	org.gradle.jvmargs
	•	kotlin.daemon.jvmargs
	•	org.gradle.workers.max

⸻

Verify

After tuning, check your active daemons:

./gradlew --status
jps -lv | grep GradleDaemon
PID=$(jps -lv | awk '/GradleDaemon/ {print $1; exit}')
jcmd $PID VM.flags | grep -E "MaxHeapSize|UseCompressedOops"

You should see:
	•	MaxHeapSize at the tuned value (e.g. 4294967296 for 4g)
	•	UseCompressedOops = true

⸻

Limitations
	•	Benchmarks are local only — your machine, your repo.
	•	Synthetic task ≈ good baseline, but always confirm with a real task.
	•	Only supports macOS & Linux for now (/usr/bin/time -l required).
	•	Requires Python 3 for tiny arithmetic snippets.

⸻

Roadmap
	•	Windows support
	•	HTML/Markdown reports of benchmark results
	•	Profile per project as well as per Gradle version
	•	Homebrew tap for easier installation
	•	CI integration (auto-tune once, commit gradle-tuner.json?)

⸻

License

MIT — do whatever, just credit.

⸻

Example Session

$ gradle-tune
gradle-sweetspot: 12 cores, 64 GB RAM
Task: sweetspotBenchmark
Candidates:
  4g 2g 6
  6g 3g 6
  8g 4g 6
== c1_G4g_K2g_W6 ==
  -> WALL=68.2 RSS_KB=3150000 GC_PCT=2.1
  -> score=68.5
== c2_G6g_K3g_W6 ==
  -> WALL=61.7 RSS_KB=4950000 GC_PCT=1.9
  -> score=62.2
== c3_G8g_K4g_W6 ==
  -> WALL=62.3 RSS_KB=7200000 GC_PCT=1.8
  -> score=63.0

Winner: c2_G6g_K3g_W6
  wall=61.7s rss=4950000KB gc=1.9%
  gradleXmx=6g kotlinXmx=3g workers=6
Saved ~/.gradle/gradle-tuner.json

