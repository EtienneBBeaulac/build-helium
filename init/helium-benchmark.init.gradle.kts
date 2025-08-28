// File: helium-benchmark.init.gradle.kts
// Registers portable, synthetic heavy benchmark tasks in EVERY Gradle build.
// Usage:
//   ./gradlew heliumBenchmark
//   ./gradlew heliumBenchmarkBig
//
// Tunables via -P (apply to both tasks unless overridden in the Big preset):
//   -Phelium.actions=400         // number of parallel work items (default 300)
//   -Phelium.repeats=150         // SHA-256 repeat rounds per item (default 120)
//   -Phelium.sizeKB=128          // payload size per item in KiB (default 96)
//   -Phelium.useDisk=false       // if false, generate bytes in-memory (no I/O). default true
//   -Phelium.deterministic=true  // if true, RNG is seeded by index. default true
//
// Notes:
// - Uses Worker API with noIsolation() to exercise the Gradle worker pool.
// - Disables caching/up-to-date checks so every run performs real work.
// - If useDisk=true, files are written under build/helium/{inputs,outputs}.
// - If useDisk=false, payloads are generated (re)producibly inside each worker.

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.*
import org.gradle.workers.WorkAction
import org.gradle.workers.WorkParameters
import org.gradle.workers.WorkerExecutor
import java.io.File
import java.security.MessageDigest
import java.util.Random
import javax.inject.Inject

@DisableCachingByDefault(because = "Synthetic benchmark must always do work")
abstract class HeliumBenchmark @Inject constructor() : DefaultTask() {

    @get:Inject
    abstract val workerExecutor: WorkerExecutor

    @get:Input
    val actions: Property<Int> = project.objects.property(Int::class.java).convention(300)

    @get:Input
    val repeats: Property<Int> = project.objects.property(Int::class.java).convention(120)

    @get:Input
    val sizeKB: Property<Int> = project.objects.property(Int::class.java).convention(96)

    @get:Input
    val useDisk: Property<Boolean> = project.objects.property(Boolean::class.java).convention(true)

    @get:Input
    val deterministic: Property<Boolean> = project.objects.property(Boolean::class.java).convention(true)

    @get:OutputDirectory
    val outDir: DirectoryProperty = project.layout.buildDirectory.dir("helium/outputs")

    // For disk mode we also materialize inputs so Gradle knows where they go.
    @get:OutputDirectory
    val inDir: DirectoryProperty = project.layout.buildDirectory.dir("helium/inputs")

    init {
        group = "verification"
        description = "Synthetic CPU+alloc (+optional I/O) workload for build-helium tuning"
        outputs.upToDateWhen { false }  // always run
        outputs.cacheIf { false }       // never cache
    }

    @TaskAction
    fun run() {
        val queue = workerExecutor.noIsolation()
        val salt = System.nanoTime().toString() // differentiates runs; fed into hashing
        val out = outDir.get().asFile.apply { mkdirs() }
        val inRoot = inDir.get().asFile

        val doDisk = useDisk.get()
        if (doDisk) inRoot.mkdirs()

        val a = actions.get()
        val r = repeats.get()
        val sz = sizeKB.get()

        repeat(a) { idx ->
            val output = File(out, "out-$idx.bin")

            val inputFile: File? = if (doDisk) {
                val f = File(inRoot, "in-$idx.bin")
                f.parentFile.mkdirs()
                f.outputStream().use { os ->
                    val buf = ByteArray(sz * 1024)
                    val seed = if (deterministic.get()) idx.toLong() else System.nanoTime() + idx
                    Random(seed).nextBytes(buf)
                    os.write(buf)
                }
                f
            } else null

            queue.submit(HeliumHashAction::class.java) {
                it.index.set(idx)
                it.sizeKB.set(sz)
                it.repeat.set(r)
                it.salt.set(salt)
                it.useDisk.set(doDisk)
                it.deterministic.set(deterministic.get())
                if (inputFile != null) it.inputFile.set(inputFile)
                it.outputFile.set(output)
            }
        }

        workerExecutor.await()

        logger.lifecycle(
            "heliumBenchmark: {} actions × {} repeats × {} KB (useDisk={}, deterministic={})",
            a, r, sz, doDisk, deterministic.get()
        )
    }
}

abstract class HeliumHashAction : WorkAction<HeliumHashAction.Params> {
    interface Params : WorkParameters {
        val index: Property<Int>
        val sizeKB: Property<Int>
        val repeat: Property<Int>
        val salt: Property<String>
        val useDisk: Property<Boolean>
        val deterministic: Property<Boolean>
        val inputFile: RegularFileProperty
        val outputFile: RegularFileProperty
    }

    override fun execute() {
        val useDisk = parameters.useDisk.get()
        val size = parameters.sizeKB.get() * 1024

        val payload: ByteArray = if (useDisk) {
            parameters.inputFile.get().asFile.readBytes()
        } else {
            val seed = if (parameters.deterministic.get())
                parameters.index.get().toLong()
            else
                System.nanoTime() + parameters.index.get()
            val buf = ByteArray(size)
            Random(seed).nextBytes(buf)
            buf
        }

        val md = MessageDigest.getInstance("SHA-256")
        var digest = payload
        repeat(parameters.repeat.get()) {
            md.update(digest)
            md.update(parameters.salt.get().toByteArray())
            digest = md.digest()
        }
        parameters.outputFile.get().asFile.outputStream().use { it.write(digest) }
    }
}

// ---- Registration (root project only) ----
gradle.rootProject {
    // Resolve -P overrides if provided
    fun Project.propInt(name: String): Int? =
        (findProperty(name) as String?)?.toIntOrNull()
    fun Project.propBool(name: String): Boolean? =
        (findProperty(name) as String?)?.toBooleanStrictOrNull()

    tasks.register("heliumBenchmark", HeliumBenchmark::class.java) {
        propInt("helium.actions")?.let(it.actions::set)
        propInt("helium.repeats")?.let(it.repeats::set)
        propInt("helium.sizeKB") ?.let(it.sizeKB::set)
        propBool("helium.useDisk")?.let(it.useDisk::set)
        propBool("helium.deterministic")?.let(it.deterministic::set)
    }

    tasks.register("heliumBenchmarkBig", HeliumBenchmark::class.java) {
        actions.set(500)
        repeats.set(160)
        sizeKB.set(128)
        // Carry over global -P toggles if present:
        propBool("helium.useDisk")?.let(useDisk::set)
        propBool("helium.deterministic")?.let(deterministic::set)
    }
}