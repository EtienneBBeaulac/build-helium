// Registers a synthetic, heavy benchmark task in the root project.
// Usage: ./gradlew sweetspotBenchmark
// Tunables via -P: -Psweetspot.actions=400 -Psweetspot.repeats=150 -Psweetspot.sizeKB=128

import org.gradle.api.*
import org.gradle.api.provider.Property
import org.gradle.api.file.*
import org.gradle.api.tasks.*
import org.gradle.workers.*
import java.security.MessageDigest
import java.util.Random
import javax.inject.Inject

abstract class SweetspotBenchmark @Inject constructor() : DefaultTask() {
    @get:Inject abstract val workerExecutor: WorkerExecutor

    @get:Input
    val actions: Property<Int> = project.objects.property(Int::class.java).convention(300)

    @get:Input
    val repeats: Property<Int> = project.objects.property(Int::class.java).convention(120)

    @get:Input
    val sizeKB: Property<Int> = project.objects.property(Int::class.java).convention(96)

    @get:OutputDirectory
    val outDir: DirectoryProperty = project.layout.buildDirectory.dir("sweetspot/outputs")

    init {
        // Always run (don’t cache or consider up-to-date)
        outputs.upToDateWhen { false }
    }

    @TaskAction
    fun run() {
        val queue = workerExecutor.noIsolation()
        val salt = System.nanoTime().toString()
        val out = outDir.get().asFile.apply { mkdirs() }

        repeat(actions.get()) { idx ->
            val input = project.layout.buildDirectory
                .file("sweetspot/inputs/in-$idx.bin").get().asFile
            input.parentFile.mkdirs()
            input.outputStream().use { os ->
                val r = Random(idx.toLong())
                val buf = ByteArray(sizeKB.get() * 1024)
                r.nextBytes(buf); os.write(buf)
            }
            val output = File(out, "out-$idx.bin")

            queue.submit(HashAction::class.java) {
                it.inputFile.set(input)
                it.outputFile.set(output)
                it.repeat.set(repeats.get())
                it.salt.set(salt)
            }
        }
        workerExecutor.await()
    }
}

abstract class HashAction : WorkAction<HashAction.Params> {
    interface Params : WorkParameters {
        val inputFile: RegularFileProperty
        val outputFile: RegularFileProperty
        val repeat: Property<Int>
        val salt: Property<String>
    }
    override fun execute() {
        val bytes = params.inputFile.get().asFile.readBytes()
        val md = MessageDigest.getInstance("SHA-256")
        var digest = bytes
        repeat(params.repeat.get()) {
            md.update(digest); md.update(params.salt.get().toByteArray())
            digest = md.digest()
        }
        params.outputFile.get().asFile.outputStream().use { it.write(digest) }
    }
}

gradle.beforeProject {
    // only register once, on the root project
    if (this == rootProject) {
        val actions = (findProperty("sweetspot.actions") as String?)?.toIntOrNull()
        val repeats = (findProperty("sweetspot.repeats") as String?)?.toIntOrNull()
        val sizeKB  = (findProperty("sweetspot.sizeKB")  as String?)?.toIntOrNull()

        tasks.register("sweetspotBenchmark", SweetspotBenchmark::class.java) {
            if (actions != null) it.actions.set(actions)
            if (repeats != null) it.repeats.set(repeats)
            if (sizeKB  != null) it.sizeKB.set(sizeKB)
            // Make it obviously parallelizable:
            it.outputs.cacheIf { false }
        }

        // A “bigger” preset if you want to stress more:
        tasks.register("sweetspotBenchmarkBig", SweetspotBenchmark::class.java) {
            it.actions.set(500)
            it.repeats.set(160)
            it.sizeKB.set(128)
            it.outputs.cacheIf { false }
        }
    }
}
