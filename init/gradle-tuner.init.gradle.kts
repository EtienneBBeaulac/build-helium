import java.nio.file.Files
import java.nio.file.Paths

data class TunerCfg(
  val gradleVersionKey: String? = null,
  val gradleJvmArgs: String? = null,
  val kotlinDaemonJvmArgs: String? = null,
  val workersMax: Int? = null
)

fun loadCfg(): TunerCfg? {
  val p = Paths.get(System.getProperty("user.home"), ".gradle", "gradle-tuner.json")
  if (!Files.exists(p)) return null
  val text = Files.readString(p)

  fun grab(key: String): String? =
    Regex("\"$key\"\\s*:\\s*\"([^\"]+)\"").find(text)?.groupValues?.getOrNull(1)
  fun grabInt(key: String): Int? =
    Regex("\"$key\"\\s*:\\s*(\\d+)").find(text)?.groupValues?.getOrNull(1)?.toInt()

  return TunerCfg(
    gradleVersionKey = grab("gradleVersionKey"),
    gradleJvmArgs = grab("gradleJvmArgs"),
    kotlinDaemonJvmArgs = grab("kotlinDaemonJvmArgs"),
    workersMax = grabInt("workersMax")
  )
}

gradle.beforeSettings {
  val cfg = loadCfg() ?: return@beforeSettings

  // Force properties so they override project gradle.properties
  cfg.gradleJvmArgs?.let { System.setProperty("org.gradle.jvmargs", it) }
  cfg.kotlinDaemonJvmArgs?.let { System.setProperty("kotlin.daemon.jvmargs", it) }
  cfg.workersMax?.let { System.setProperty("org.gradle.workers.max", it.toString()) }
}
